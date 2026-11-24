#ifndef MATHUTIL_H
#define MATHUTIL_H

/* Greatest common divisor; gcd(0, 0) == 0. */
int mu_gcd(int a, int b);
/* Clamps v to [lo, hi]. */
int mu_clamp(int v, int lo, int hi);

#endif
