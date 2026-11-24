#include "mathutil.h"

int mu_gcd(int a, int b) {
    if (a < 0)
        a = -a;
    if (b < 0)
        b = -b;
    while (b != 0) {
        int t = a % b;
        a = b;
        b = t;
    }
    return a;
}

int mu_clamp(int v, int lo, int hi) {
    return v < lo ? lo : v > hi ? hi
                                : v;
}
