#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_RULES 1024
#define MAX_IPS 256
#define MAX_CACHE 8192
#define MAX_CHILDREN 32
#define CACHE "/tmp/flowproxy/domain-cache"
#define READY "/tmp/flowproxy/dns.ready"
#ifndef NFT_BIN
#define NFT_BIN "/usr/sbin/nft"
#endif
struct config { struct sockaddr_in upstream, direct, listen; char suffix[MAX_RULES][254], keyword[MAX_RULES][254]; size_t ns, nk; };
struct record { char host[254], ip[INET_ADDRSTRLEN]; uint64_t expiry; };
struct answer { char ip[INET_ADDRSTRLEN]; uint32_t ttl; };
static volatile sig_atomic_t running = 1;
static void stopped(int sig) { (void)sig; running = 0; }
static uint16_t be16(const unsigned char *p) { return ((uint16_t)p[0] << 8) | p[1]; }
static uint32_t be32(const unsigned char *p) { return ((uint32_t)be16(p) << 16) | be16(p + 2); }
static int addr(struct sockaddr_in *a, const char *ip, unsigned port) {
    memset(a, 0, sizeof(*a)); a->sin_family = AF_INET; a->sin_port = htons(port);
    return port > 0 && port <= 65535 && inet_pton(AF_INET, ip, &a->sin_addr) == 1;
}
static int valid_host(const char *s) {
    size_t n = strlen(s); if (!n || n > 253 || s[0] == '.' || s[n-1] == '.') return 0;
    for (size_t i = 0; i < n; i++) if (!(isalnum((unsigned char)s[i]) || s[i] == '-' || s[i] == '_' || s[i] == '.')) return 0;
    return strstr(s, "..") == NULL;
}
static int valid_keyword(const char *s) {
    size_t n=strlen(s); if(!n||n>253)return 0;
    for(size_t i=0;i<n;i++)if(!(isalnum((unsigned char)s[i])||s[i]=='-'||s[i]=='_'||s[i]=='.'))return 0;
    return 1;
}
static int load_config(const char *path, struct config *c) {
    memset(c, 0, sizeof(*c)); addr(&c->listen, "127.0.0.1", 5533);
    FILE *f = fopen(path, "r"); if (!f) return -1;
    char line[1024], type[32], value[300], extra[2]; unsigned port;
    int up = 0, direct = 0, bad = 0;
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "%31s", type) != 1) { bad = 1; break; }
        if (!strcmp(type, "upstream") || !strcmp(type, "direct") || !strcmp(type, "listen")) {
            if (sscanf(line, "%31s %299s %u %1s", type, value, &port, extra) != 3) { bad = 1; break; }
            struct sockaddr_in *a = !strcmp(type, "upstream") ? &c->upstream : !strcmp(type, "direct") ? &c->direct : &c->listen;
            if (!addr(a, value, port)) { bad = 1; break; }
            if (!strcmp(type, "upstream")) up = 1;
            if (!strcmp(type, "direct")) direct = 1;
        } else if (!strcmp(type, "suffix") || !strcmp(type, "keyword")) {
            if (sscanf(line, "%31s %299s %1s", type, value, extra) != 2 || (!strcmp(type,"suffix") ? !valid_host(value) : !valid_keyword(value))) { bad = 1; break; }
            for (char *p = value; *p; p++) *p = (char)tolower((unsigned char)*p);
            if (!strcmp(type, "suffix")) {
                if (c->ns >= MAX_RULES) { bad = 1; break; } strcpy(c->suffix[c->ns++], value);
            } else {
                if (c->nk >= MAX_RULES) { bad = 1; break; } strcpy(c->keyword[c->nk++], value);
            }
        } else { bad = 1; break; }
    }
    fclose(f);
    /* Listening on loopback only. Never permit the default upstream to loop back here. */
    if (ntohl(c->listen.sin_addr.s_addr) != INADDR_LOOPBACK ||
        (c->upstream.sin_addr.s_addr == c->listen.sin_addr.s_addr && c->upstream.sin_port == c->listen.sin_port) ||
        (c->direct.sin_addr.s_addr == c->listen.sin_addr.s_addr && c->direct.sin_port == c->listen.sin_port)) bad = 1;
    return (!bad && up && direct) ? 0 : -1;
}
static int matches(const struct config *c, const char *host) {
    size_t n = strlen(host);
    for (size_t i = 0; i < c->ns; i++) { size_t m = strlen(c->suffix[i]); if (n >= m && !strcmp(host + n - m, c->suffix[i]) && (n == m || host[n-m-1] == '.')) return 1; }
    for (size_t i = 0; i < c->nk; i++) if (strstr(host, c->keyword[i])) return 1;
    return 0;
}
/* DNS compression is bounded independently of packet length to reject pointer loops. */
static int name_at(const unsigned char *b, size_t len, size_t *offset, char out[254]) {
    size_t p = *offset, used = 0, resume = 0, hops = 0; int jumped = 0;
    while (p < len && hops++ < 128) {
        unsigned v = b[p++];
        if ((v & 0xc0) == 0xc0) {
            if (p >= len) return -1;
            size_t target = ((size_t)(v & 0x3f) << 8) | b[p++];
            if (!jumped) resume = p;
            jumped = 1; p = target; continue;
        }
        if (v & 0xc0 || v > 63 || p + v > len) return -1;
        if (!v) { out[used] = 0; *offset = jumped ? resume : p; return 0; }
        if (used) { if (used >= 253) return -1; out[used++] = '.'; }
        if (used + v > 253) return -1;
        for (unsigned i = 0; i < v; i++) { unsigned ch = b[p++]; if (!(isalnum(ch) || ch == '-' || ch == '_')) return -1; out[used++] = (char)tolower(ch); }
    }
    return -1;
}
static int question(const unsigned char *b, size_t n, char host[254]) {
    size_t p = 12;
    return n >= 12 && be16(b+4) == 1 && name_at(b, n, &p, host) == 0 && p + 4 <= n ? 0 : -1;
}
static int answers(unsigned char *b, size_t len, struct answer *a, size_t *count) {
    size_t p = 12; char name[254]; *count = 0;
    if (len < 12 || (b[3] & 15) || (b[2] & 2)) return 0;
    unsigned q = be16(b+4), nr = be16(b+6);
    for (unsigned i = 0; i < q; i++) { if (name_at(b,len,&p,name) || p+4 > len) return -1; p += 4; }
    for (unsigned i = 0; i < nr; i++) {
        if (name_at(b,len,&p,name) || p+10 > len) return -1;
        uint16_t type = be16(b+p), cls = be16(b+p+2), size = be16(b+p+8); uint32_t ttl = be32(b+p+4);
        if (p+10+size > len) return -1;
        if (type == 1 && cls == 1 && size == 4) {
            if (*count >= MAX_IPS) return -1;
            if (ttl > 604800) { ttl = 604800; b[p+4]=0; b[p+5]=9; b[p+6]=0x3a; b[p+7]=0x80; }
            char ip[INET_ADDRSTRLEN]; inet_ntop(AF_INET, b+p+10, ip, sizeof(ip));
            size_t index; for(index=0;index<*count;index++)if(!strcmp(a[index].ip,ip))break;
            if(index==*count) {strcpy(a[index].ip,ip);a[index].ttl=0;(*count)++;}
            /* Cover DNS transport/cache rounding without shortening an already
             * valid address shared by another matching hostname. */
            ttl += 30;
            if(a[index].ttl<ttl)a[index].ttl=ttl;
        }
        p += 10 + size;
    }
    return 0;
}
static int cache_lock(void) { int f = open(CACHE ".lock", O_CREAT|O_RDWR|O_CLOEXEC,0600); if (f < 0 || flock(f,LOCK_EX)) { if (f>=0) close(f); return -1; } return f; }
static struct record *cache_read(const struct config *c, size_t *count) {
    struct record *r = calloc(MAX_CACHE,sizeof(*r)); *count = 0; if (!r) return NULL;
    FILE *f = fopen(CACHE,"r"); if (!f) return r;
    unsigned long long exp; char host[254], ip[INET_ADDRSTRLEN], line[512]; uint64_t now = (uint64_t)time(NULL); struct in_addr v;
    while (fgets(line,sizeof(line),f)) {
        if (sscanf(line,"%llu %253s %15s",&exp,host,ip) != 3 || exp <= now || exp > now+604830 || !valid_host(host) || inet_pton(AF_INET,ip,&v) != 1 || !matches(c,host)) continue;
        size_t i; for (i=0;i<*count;i++) if (!strcmp(r[i].host,host) && !strcmp(r[i].ip,ip)) break;
        if (i == MAX_CACHE) continue;
        if (i == *count) { strcpy(r[i].host,host); strcpy(r[i].ip,ip); (*count)++; }
        if (r[i].expiry < exp) r[i].expiry = exp;
    }
    fclose(f); return r;
}
static int cache_append_locked(const struct config *c, const char *host, struct answer *a, size_t n) {
    if (!n) return 0;
    struct stat st;
    if (!stat(CACHE,&st) && st.st_size > 1048576) {
        size_t count; struct record *r = cache_read(c,&count);
        FILE *f = r ? fopen(CACHE ".new","w") : NULL;
        if (f) { for (size_t i=0;i<count;i++) fprintf(f,"%llu %s %s\n",(unsigned long long)r[i].expiry,r[i].host,r[i].ip); fclose(f); rename(CACHE ".new",CACHE); }
        free(r);
    }
    FILE *f = fopen(CACHE,"a");
    int rc=-1;
    if (f) { uint64_t now = (uint64_t)time(NULL); for(size_t i=0;i<n;i++) fprintf(f,"%llu %s %s\n",(unsigned long long)(now+a[i].ttl),host,a[i].ip); rc=ferror(f)?-1:0; if(fclose(f))rc=-1; }
    return rc;
}
static int restore(const struct config *c) {
    int lock = cache_lock(); if (lock < 0) return -1;
    size_t count; struct record *r = cache_read(c,&count); if (!r) { close(lock); return -1; }
    uint64_t now=(uint64_t)time(NULL); int first=1;
    for(size_t i=0;i<count;i++) {
        if (!r[i].ip[0]) continue;
        for(size_t j=i+1;j<count;j++) if (!strcmp(r[i].ip,r[j].ip)) { if(r[i].expiry < r[j].expiry) r[i].expiry=r[j].expiry; r[j].ip[0]=0; }
        if(r[i].expiry<=now) continue;
        if(first) { printf("        elements = { "); first=0; } else printf(", ");
        printf("%s timeout %llus",r[i].ip,(unsigned long long)(r[i].expiry-now));
    }
    if(!first) puts(" }");
    free(r); close(lock); return 0;
}
static int apply_answers(struct answer *a,size_t n) {
    if(!n) return 0;
    int fd[2]; if(pipe(fd)) return -1;
    pid_t p=fork(); if(p<0) {close(fd[0]);close(fd[1]);return -1;}
    if(!p) { dup2(fd[0],STDIN_FILENO);close(fd[0]);close(fd[1]);execl(NFT_BIN,"nft","-f","-",(char*)NULL);_exit(127); }
    close(fd[0]); FILE *f=fdopen(fd[1],"w");
    if(!f) {close(fd[1]);kill(p,SIGTERM);waitpid(p,NULL,0);return -1;}
    fprintf(f,"add element inet flowproxy fp_direct_domains { ");
    for(size_t i=0;i<n;i++) fprintf(f,"%s%s timeout %us",i?", ":"",a[i].ip,a[i].ttl);
    fprintf(f," }\n"); int err=fclose(f), status; while(waitpid(p,&status,0)<0) if(errno!=EINTR) return -1;
    return !err && WIFEXITED(status) && WEXITSTATUS(status)==0 ? 0 : -1;
}
static int install_answers(const struct config *c,const char *host,struct answer *a,size_t n) {
    if(!n)return 0;
    int lock=cache_lock();if(lock<0)return -1;
    int rc=cache_append_locked(c,host,a,n);
    struct answer effective[MAX_IPS];memcpy(effective,a,n*sizeof(*a));
    size_t count=0;struct record *cached=cache_read(c,&count);uint64_t now=(uint64_t)time(NULL);
    if(!cached)rc=-1;
    if(!rc) {
        for(size_t i=0;i<n;i++)for(size_t j=0;j<count;j++)
            if(!strcmp(effective[i].ip,cached[j].ip)&&cached[j].expiry>now+effective[i].ttl)
                effective[i].ttl=(uint32_t)(cached[j].expiry-now);
        rc=apply_answers(effective,n);
    }
    free(cached);close(lock);return rc;
}
static void io_timeout(int s) { struct timeval tv={2,0}; setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));setsockopt(s,SOL_SOCKET,SO_SNDTIMEO,&tv,sizeof(tv)); }
static int full_io(int s,void *buf,size_t n,int writing) {
    size_t p=0; while(p<n) { ssize_t r=writing?send(s,(char*)buf+p,n-p,MSG_NOSIGNAL):recv(s,(char*)buf+p,n-p,0); if(r<0&&errno==EINTR)continue; if(r<=0)return -1;p+=(size_t)r; } return 0;
}
static ssize_t exchange(const struct sockaddr_in *target,int tcp,const unsigned char *q,size_t qlen,unsigned char *r) {
    int s=socket(AF_INET,tcp?SOCK_STREAM:SOCK_DGRAM,0);if(s<0)return -1;io_timeout(s);
    int flags=fcntl(s,F_GETFL,0);fcntl(s,F_SETFL,flags|O_NONBLOCK);
    int connected=connect(s,(const struct sockaddr*)target,sizeof(*target));
    if(connected && errno==EINPROGRESS) { struct pollfd p={s,POLLOUT,0};int err=0;socklen_t size=sizeof(err); connected=poll(&p,1,2000)>0 && !getsockopt(s,SOL_SOCKET,SO_ERROR,&err,&size) && !err ? 0:-1; }
    fcntl(s,F_SETFL,flags); if(connected) {close(s);return -1;}
    ssize_t n=-1;
    if(tcp) {
        unsigned char prefix[2]={(unsigned char)(qlen>>8),(unsigned char)qlen};
        if(!full_io(s,prefix,2,1)&&!full_io(s,(void*)q,qlen,1)&&!full_io(s,prefix,2,0)) { size_t z=be16(prefix);if(z>=12&&!full_io(s,r,z,0))n=(ssize_t)z; }
    } else if(send(s,q,qlen,0)==(ssize_t)qlen) n=recv(s,r,65535,0);
    close(s);return n;
}
static ssize_t resolve_query(const struct config *c,int tcp,const unsigned char *q,size_t qlen,unsigned char *r) {
    char host[254], response_host[254]; if(qlen<12 || (q[2]&0x80))return -1;
    int parsed=!question(q,qlen,host), direct=parsed&&matches(c,host);
    ssize_t n=exchange(direct?&c->direct:&c->upstream,tcp,q,qlen,r);
    if(n<12 || r[0]!=q[0] || r[1]!=q[1] || !(r[2]&0x80) || (parsed&&(question(r,(size_t)n,response_host)||strcmp(host,response_host)))) return -1;
    if(direct) {
        struct answer a[MAX_IPS];size_t count;
        if(answers(r,(size_t)n,a,&count))return -1;
        if(install_answers(c,host,a,count)) {fprintf(stderr,"flowproxy-dns: cannot install/cache direct addresses for %s\n",host);return -1;}
    }
    return n;
}
static size_t servfail(const unsigned char *q,size_t n,unsigned char *r) {
    if(n<12)return 0;
    memcpy(r,q,n);r[2]|=0x80;r[3]=(r[3]&0xf0)|2;memset(r+6,0,6);return n;
}
static void udp_worker(const struct config *c,int socket,const unsigned char *q,size_t qlen,const struct sockaddr_in *client,socklen_t cl) {
    unsigned char r[65535];ssize_t n=resolve_query(c,0,q,qlen,r);if(n<0)n=(ssize_t)servfail(q,qlen,r);
    if(n>0)sendto(socket,r,(size_t)n,0,(const struct sockaddr*)client,cl);
}
static void tcp_worker(const struct config *c,int s) {
    unsigned char q[65535],r[65535],prefix[2];io_timeout(s);
    for(unsigned i=0;i<16;i++) {
        if(full_io(s,prefix,2,0))break;
        size_t len=be16(prefix);if(len<12||full_io(s,q,len,0))break;
        ssize_t n=resolve_query(c,1,q,len,r);if(n<0)n=(ssize_t)servfail(q,len,r);
        prefix[0]=(unsigned char)((unsigned)n>>8);prefix[1]=(unsigned char)n;
        if(full_io(s,prefix,2,1)||full_io(s,r,(size_t)n,1))break;
    }
}
static int listener(const struct sockaddr_in *a,int type) {
    int s=socket(AF_INET,type|SOCK_CLOEXEC,0);if(s<0)return -1;int one=1;setsockopt(s,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    if(bind(s,(const struct sockaddr*)a,sizeof(*a)) || (type==SOCK_STREAM&&listen(s,32))) {close(s);return -1;}return s;
}
#ifndef UNIT_TEST
/* Query the running bridge directly. BusyBox nslookup variants disagree on
 * both -type and non-standard port syntax, so do not rely on them for warming. */
static int warm(const struct config *c) {
    int failed = 0;
    for (size_t i = 0; i < c->ns; i++) {
        unsigned char q[512] = {0}, r[65535];
        uint16_t id = (uint16_t)((unsigned)getpid() + i);
        q[0] = (unsigned char)(id >> 8); q[1] = (unsigned char)id;
        q[2] = 1; q[5] = 1;
        size_t offset = 12;
        const char *label = c->suffix[i];
        int invalid = 0;
        while (*label) {
            const char *dot = strchr(label, '.');
            size_t len = dot ? (size_t)(dot-label) : strlen(label);
            if (!len || len > 63 || offset + len + 6 > sizeof(q)) { invalid = 1; break; }
            q[offset++] = (unsigned char)len; memcpy(q+offset, label, len); offset += len;
            if (!dot) break;
            label = dot+1;
        }
        if (invalid) { failed = 1; continue; }
        q[offset++] = 0; q[offset++] = 0; q[offset++] = 1; q[offset++] = 0; q[offset++] = 1;
        ssize_t n = exchange(&c->listen, 0, q, offset, r);
        if (n >= 12 && (r[2] & 2)) n = exchange(&c->listen, 1, q, offset, r);
        if (n < 12 || r[0] != q[0] || r[1] != q[1] || (r[3] & 15) == 2) failed = 1;
    }
    return failed;
}
int main(int argc,char **argv) {
    if(argc<2||argc>3) {fprintf(stderr,"usage: flowproxy-dns CONFIG [--check|--restore|--warm]\n");return 2;}
    struct config *c=calloc(1,sizeof(*c));if(!c||load_config(argv[1],c)) {fprintf(stderr,"flowproxy-dns: invalid configuration\n");free(c);return 2;}
    if(argc==3) {int rc=!strcmp(argv[2],"--check")?0:!strcmp(argv[2],"--restore")?restore(c):!strcmp(argv[2],"--warm")?warm(c):2;free(c);return rc?2:0;}
    umask(077);signal(SIGPIPE,SIG_IGN);signal(SIGTERM,stopped);signal(SIGINT,stopped);
    int udp=listener(&c->listen,SOCK_DGRAM),tcp=listener(&c->listen,SOCK_STREAM);if(udp<0||tcp<0) {perror("flowproxy-dns: bind");return 1;}
    FILE *ready=fopen(READY,"w");if(!ready)return 1;fprintf(ready,"%ld\n",(long)getpid());fclose(ready);
    pid_t children[MAX_CHILDREN]={0};
    while(running) {
        for(size_t i=0;i<MAX_CHILDREN;i++)if(children[i]&&waitpid(children[i],NULL,WNOHANG)==children[i])children[i]=0;
        struct pollfd fds[2]={{udp,POLLIN,0},{tcp,POLLIN,0}};if(poll(fds,2,500)<=0)continue;
        for(int type=0;type<2;type++)if(fds[type].revents&POLLIN) {
            unsigned char q[65535];struct sockaddr_in client;socklen_t cl=sizeof(client);ssize_t n=0;int s=udp;
            if(type) {s=accept4(tcp,NULL,NULL,SOCK_CLOEXEC);if(s<0)continue;} else {n=recvfrom(udp,q,sizeof(q),0,(struct sockaddr*)&client,&cl);if(n<12)continue;}
            size_t slot;for(slot=0;slot<MAX_CHILDREN;slot++)if(!children[slot])break;
            if(slot==MAX_CHILDREN) {if(type)close(s);else {unsigned char r[65535];size_t len=servfail(q,(size_t)n,r);sendto(udp,r,len,0,(struct sockaddr*)&client,cl);}continue;}
            pid_t p=fork();
            if(!p) {signal(SIGTERM,SIG_DFL);signal(SIGINT,SIG_DFL);alarm(8);close(tcp);if(type){close(udp);tcp_worker(c,s);close(s);}else udp_worker(c,udp,q,(size_t)n,&client,cl);_exit(0);}
            if(p>0)children[slot]=p;
            if(type)close(s);
        }
    }
    unlink(READY);close(udp);close(tcp);
    for(size_t i=0;i<MAX_CHILDREN;i++)if(children[i])kill(children[i],SIGTERM);
    while(waitpid(-1,NULL,0)>0||errno==EINTR){}free(c);return 0;
}
#endif
