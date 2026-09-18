/*
 * test_http.c - diagnostic for the dsh web HTTP client.
 *
 * Exercises the exact sequence the sender uses: token exchange, then one RPC
 * call. Prints every intermediate value so a failure names the step.
 *
 * Usage: test_http.exe <base-url> <token>
 */
#include <stdio.h>
#include <string.h>

#include "dsh_http.h"

int main(int argc, char **argv) {
    dsh_http http;
    dsh_sb body;
    dsh_sb value;
    dsh_sb error;
    dsh_sb error_code;
    int status = 0;
    int rc;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 3) {
        printf("usage: %s <base-url> <token>\n", argv[0]);
        return 2;
    }

    if (dsh_net_init() != 0) {
        printf("net init failed\n");
        return 2;
    }

    rc = dsh_http_init(&http, argv[1]);
    printf("http_init       rc=%d host='%s' port=%u\n", rc, http.host, (unsigned)http.port);
    if (rc != 0) {
        return 1;
    }

    dsh_sb_init(&body);
    rc = dsh_http_get(&http, "/", &body, &status);
    printf("unauthenticated rc=%d status=%d body=%zu bytes\n", rc, status, body.len);
    dsh_sb_free(&body);

    printf("token length    %zu\n", strlen(argv[2]));

    rc = dsh_http_login(&http, argv[2]);
    printf("login           rc=%d logged_in=%d\n", rc, http.logged_in);
    printf("cookie          '%.120s%s'\n", http.cookie, strlen(http.cookie) > 120 ? "..." : "");
    if (rc != 0) {
        printf("FAIL: token exchange did not yield a cookie\n");
        return 1;
    }

    dsh_sb_init(&value);
    dsh_sb_init(&error);
    rc = dsh_rpc_call(&http, "session/list", "{\"_request\":{}}",
                      sizeof("{\"_request\":{}}") - 1, &value, &error, &error_code);
    printf("session/list    rc=%d\n", rc);
    if (rc == 0) {
        printf("value           %.400s\n", value.buf != NULL ? value.buf : "(null)");
    } else {
        printf("error           %s\n", error.buf != NULL ? error.buf : "(null)");
    }
    dsh_sb_free(&value);
    dsh_sb_free(&error);

    dsh_sb_init(&value);
    dsh_sb_init(&error);
    rc = dsh_rpc_call(&http, "session/modelCatalog", "{}", 2, &value, &error, &error_code);
    printf("modelCatalog    rc=%d\n", rc);
    if (rc == 0) {
        printf("value           %.300s\n", value.buf != NULL ? value.buf : "(null)");
    } else {
        printf("error           %s\n", error.buf != NULL ? error.buf : "(null)");
    }
    dsh_sb_free(&value);
    dsh_sb_free(&error);

    dsh_net_shutdown();
    return 0;
}
