#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Probe only the LAN SOCKS service, without requiring a working remote node. */
static long long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int ready(int fd, short events, long long deadline) {
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) return -1;
        struct pollfd p = { fd, events, 0 };
        int rc = poll(&p, 1, (int)left);
        if (rc < 0 && errno == EINTR) continue;
        return rc > 0 && (p.revents & events) ? 0 : -1;
    }
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    char *end;
    long port = strtol(argv[2], &end, 10);
    if (*end || port < 1 || port > 65535) return 2;
    long timeout = strtol(argv[3], &end, 10);
    if (*end || timeout < 1 || timeout > 30) return 2;
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
    if (inet_pton(AF_INET, argv[1], &a.sin_addr) != 1) return 2;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 1;
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) { close(fd); return 1; }
    long long deadline = now_ms() + timeout * 1000;
    int rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    int error = 0;
    socklen_t size = sizeof(error);
    if ((rc && errno != EINPROGRESS) || ready(fd, POLLOUT, deadline) ||
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) {
        close(fd); return 1;
    }
    const unsigned char greeting[] = { 5, 1, 0 };
    size_t sent = 0, received = 0;
    unsigned char answer[2];
    while (sent < sizeof(greeting)) {
        if (ready(fd, POLLOUT, deadline)) { close(fd); return 1; }
        ssize_t n = send(fd, greeting + sent, sizeof(greeting) - sent, MSG_NOSIGNAL);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) { close(fd); return 1; }
        sent += (size_t)n;
    }
    while (received < sizeof(answer)) {
        if (ready(fd, POLLIN, deadline)) { close(fd); return 1; }
        ssize_t n = recv(fd, answer + received, sizeof(answer) - received, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) { close(fd); return 1; }
        received += (size_t)n;
    }
    close(fd);
    return answer[0] == 5 && answer[1] == 0 ? 0 : 1;
}
