#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

#ifndef RESOLVER_WIN
#define RESOLVER_WIN "Z:\\invalid"
#endif
#ifndef LOGFILE_WIN
#define LOGFILE_WIN "C:\\vrchat-video-resolver.log"
#endif

// the resolver connects before it starts work, so this only catches a failed launch
#define ACCEPT_TIMEOUT_S 15
// it holds the connection open while it waits for the stream, and vrchat gives up first
#define READ_TIMEOUT_S 120

#define ARGS_MAX 8192

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64(const unsigned char *in, size_t n, char *out) {
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        unsigned v = in[i] << 16;
        if (i + 1 < n) v |= in[i + 1] << 8;
        if (i + 2 < n) v |= in[i + 2];
        out[o++] = B64[(v >> 18) & 63];
        out[o++] = B64[(v >> 12) & 63];
        out[o++] = i + 1 < n ? B64[(v >> 6) & 63] : '=';
        out[o++] = i + 2 < n ? B64[v & 63] : '=';
    }
    out[o] = 0;
}

static void fail(const char *why) {
    FILE *log = fopen(LOGFILE_WIN, "a");
    if (log) {
        fprintf(log, "shim: %s\n", why);
        fclose(log);
    }
}

int main(int argc, char **argv) {
    // base64 keeps argv clear of every character wine's command line splitter cares about
    char blob[ARGS_MAX];
    size_t len = 0;
    for (int i = 1; i < argc; i++) {
        size_t n = strlen(argv[i]);
        if (len + n + 1 > sizeof blob) {
            fail("arguments too long");
            return 1;
        }
        memcpy(blob + len, argv[i], n);
        len += n;
        blob[len++] = '\n';
    }
    char encoded[ARGS_MAX * 4 / 3 + 8];
    b64((const unsigned char *)blob, len, encoded);

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fail("could not start winsock");
        return 1;
    }

    // a pipe to a unix child has no unix fd, so the resolver answers over loopback instead
    SOCKET srv = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    ZeroMemory(&addr, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    int addrlen = sizeof addr;
    if (srv == INVALID_SOCKET || bind(srv, (struct sockaddr *)&addr, addrlen) != 0 ||
        listen(srv, 1) != 0 || getsockname(srv, (struct sockaddr *)&addr, &addrlen) != 0) {
        fail("could not listen on loopback");
        return 1;
    }

    char cmd[sizeof encoded + MAX_PATH + 32];
    snprintf(cmd, sizeof cmd, "%s %d %s", RESOLVER_WIN, ntohs(addr.sin_port), encoded);
    STARTUPINFOA si;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof pi);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        fail("could not start the resolver");
        return 1;
    }
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(srv, &readable);
    struct timeval timeout = { ACCEPT_TIMEOUT_S, 0 };
    if (select(0, &readable, NULL, NULL, &timeout) != 1) {
        fail("resolver did not connect");
        return 1;
    }
    SOCKET conn = accept(srv, NULL, NULL);
    if (conn == INVALID_SOCKET) {
        fail("could not accept the resolver");
        return 1;
    }
    DWORD ms = READ_TIMEOUT_S * 1000;
    setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, (const char *)&ms, sizeof ms);

    char buf[16384];
    size_t got = 0;
    for (;;) {
        int n = recv(conn, buf + got, (int)(sizeof buf - got), 0);
        if (n <= 0) break;
        got += n;
        if (got == sizeof buf) break;
    }
    if (got == 0) {
        // the resolver closing without writing is a failure it has already logged and reported
        fail("resolver produced no output");
        return 1;
    }
    fwrite(buf, 1, got, stdout);
    fflush(stdout);
    return 0;
}
