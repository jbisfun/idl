/* A plain C test: idl builds it with host clang, runs it and treats exit
 * status 0 as a pass. */
#include <stdio.h>
#include "mathutil.h"

static int failures = 0;

#define CHECK(expr)                                                                  \
    do {                                                                             \
        if (!(expr)) {                                                               \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #expr); \
            failures++;                                                              \
        }                                                                            \
    } while (0)

int main(void) {
    CHECK(mu_gcd(12, 18) == 6);
    CHECK(mu_gcd(-4, 6) == 2);
    CHECK(mu_gcd(0, 0) == 0);
    CHECK(mu_clamp(5, 0, 3) == 3);
    CHECK(mu_clamp(-1, 0, 3) == 0);
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "ok", failures);
    return failures ? 1 : 0;
}
