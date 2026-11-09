/* The n-body benchmark in plain C: the reference for M1.8's exit criterion (native
 * Skein within 1.5x of C). The same algorithm, data layout (seven parallel arrays) and
 * order of floating-point operations as nbody.skn, so both compute the same energies.
 * Usage: nbody STEPS */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define N 5

static const double PI = 3.141592653589793;
static const double DAYS_PER_YEAR = 365.24;

static const double body_data[N][7] = {
    {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0},
    {4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
     1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
     9.54791938424326609e-04},
    {8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
     -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
     2.85885980666130812e-04},
    {1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
     2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
     4.36624404335156298e-05},
    {1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
     2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
     5.15138902046611451e-05}};

static double x[N], y[N], z[N], vx[N], vy[N], vz[N], m[N];

static void offset_momentum(double solar_mass) {
    double px = 0.0, py = 0.0, pz = 0.0;
    for (int i = 0; i < N; i++) {
        px = px + vx[i] * m[i];
        py = py + vy[i] * m[i];
        pz = pz + vz[i] * m[i];
    }
    vx[0] = -px / solar_mass;
    vy[0] = -py / solar_mass;
    vz[0] = -pz / solar_mass;
}

static double energy(void) {
    double e = 0.0;
    for (int i = 0; i < N; i++) {
        e = e + 0.5 * m[i] * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
        for (int j = i + 1; j < N; j++) {
            double dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j];
            e = e - m[i] * m[j] / sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

static void advance(double dt) {
    for (int i = 0; i < N; i++) {
        for (int j = i + 1; j < N; j++) {
            double dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j];
            double d2 = dx * dx + dy * dy + dz * dz;
            double mag = dt / (d2 * sqrt(d2));
            vx[i] = vx[i] - dx * m[j] * mag;
            vy[i] = vy[i] - dy * m[j] * mag;
            vz[i] = vz[i] - dz * m[j] * mag;
            vx[j] = vx[j] + dx * m[i] * mag;
            vy[j] = vy[j] + dy * m[i] * mag;
            vz[j] = vz[j] + dz * m[i] * mag;
        }
    }
    for (int i = 0; i < N; i++) {
        x[i] = x[i] + dt * vx[i];
        y[i] = y[i] + dt * vy[i];
        z[i] = z[i] + dt * vz[i];
    }
}

int main(int argc, char **argv) {
    long steps = argc > 1 ? atol(argv[1]) : 1000;
    double solar_mass = 4.0 * PI * PI;
    double *arrays[7] = {x, y, z, vx, vy, vz, m};
    for (int i = 0; i < N; i++)
        for (int k = 0; k < 7; k++)
            arrays[k][i] = k == 6 ? body_data[i][k] * solar_mass
                         : k >= 3 ? body_data[i][k] * DAYS_PER_YEAR
                                  : body_data[i][k];
    offset_momentum(solar_mass);
    double before = energy();
    for (long s = 0; s < steps; s++) advance(0.01);
    printf("%.9f %.9f\n", before, energy());
    return 0;
}
