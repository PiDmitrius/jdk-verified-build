# OpenJDK Verified Build

Build OpenJDK from upstream sources and check it via
**Diverse Multi-Compilation**.

Each JDK version has its own file in [`versions/`](versions); parameters common
to all of them are in [`versions.env`](versions.env).
Select the version with `JDK_MAJOR=<major>`, default 25.

## Problem

Building JDK from source requires an existing JDK (boot JDK). A compromised
boot JDK could inject a backdoor into the compiled output -- the classic
[Trusting Trust](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf)
attack (Ken Thompson, 1984).

**How do you verify the boot JDK did not tamper with the result?**

## Solution

Build the same JDK with **multiple independent boot JDKs** and compare
the output bytewise.

Five vendors with independent build infrastructures:

| Vendor   | Identifier           | Organization       |
|----------|----------------------|--------------------|
| Temurin  | `25.0.5.0+8-tem`     | Eclipse Adoptium   |
| Corretto | `25.0.5.0+9-amzn`    | Amazon             |
| Oracle   | `25.0.0.0-oracle`    | Oracle Corporation |
| Liberica | `25.0.5.0+11-librca` | BellSoft           |
| Zulu     | `25.0.5.0+8-zulu`    | Azul Systems       |

If all 5 produce **bytewise identical** output, the choice of boot JDK did not
change the result. A boot JDK that altered the compiled output would have to be
altered the same way in every vendor. This does not prove the absence of a
backdoor shared by all vendors, or of one in the sources, the compiler or the
base image, which are common to all builds.

## Result

```
-- Comparison (reference: tem) --

  amzn = tem
  oracle = tem
  librca = tem
  zulu = tem


RESULT: ALL 5 VENDORS IDENTICAL
```

All 310 files of the JDK image are bytewise identical: native binaries, CDS
archives, the modules image, .jar archives and .jmod modules. The .deb is built
by one more compilation, and its image is checked against the same hashes.

## Usage

The build has two stages. `deps.sh` localizes every input listed in
`versions/<major>.lock`: a file already in `inputs/` with the right SHA-256 is
kept, a missing one is downloaded, verified and unpacked. `run.sh` verifies the inputs and
builds in a container with `--network none`.

```bash
./deps.sh                # needs network only for missing inputs
./verify.sh results      # offline build, compared with expected/<major>
```

Select the version with `JDK_MAJOR=<major>`, default 25.
Time: ~25 minutes on a 16-core machine (6 sequential builds + normalization).

### Offline kit

The kit is attached to the release. `./kit.sh dist/jdk-verified-25-kit.tar` packs
the builder image, the sources and the boot JDKs with one dictionary, the recipe
and the expected hashes into one archive of ~600 MB. Reproducing needs an amd64 machine with `tar`, Docker and no
network; unpacking needs 1 GiB of memory and ~3 GB of disk.

```bash
tar xf jdk-verified-25-kit.tar
cd jdk-verified-25
./verify.sh results
```

`versions/<major>.lock` holds two hashes per input: of the `.tar.gz` as published
and of the unpacked `.tar` used by the build. To check the kit against the
vendors, with network:

```bash
mkdir vendor && cp inputs/docker-builder.tar.gz vendor/
INPUTS=vendor ./deps.sh
```

The builder image is an input published with the release. `Dockerfile` and
`versions/<major>.packages` describe how it was made: to rebuild it, set its URL
in the lock to `-` and its SHA-256 to `-`. This gives the same package versions,
but not the same archive bytes.

### Output

```
results/
  openjdk-25-jdk_25.0.5.0.3-1_amd64.deb        # verified package
  hashes-*.txt                                 # SHA256 of all files
  native-*.txt                                 # SHA256 of native binaries
```

### Install on Astra Linux

```bash
sudo dpkg -i results/openjdk-25-jdk_25.0.5.0.3-1_amd64.deb
java -version
```

Installs JDK to `/usr/lib/jvm/java-25-openjdk-amd64/` and registers
`java`, `javac`, `jar`, `javadoc`, `jshell` via `update-alternatives`.

## Configuration

Version parameters in `versions/<major>.env`:

```bash
# versions/25.env
JDK_TAG="jdk-25.0.5.0.3-ga"
VENDORS=( "25.0.5.0+8-tem" ... )
SOURCE_DATE="2026-10-24"
```

Download locations and SHA-256 are in `versions/<major>.lock`, package versions in
`versions/<major>.packages`. The base image is pinned by digest in `Dockerfile`.

## How it works

### Architecture

```
Astra Linux 1.8.6 (Debian 12) container
+---------------------------------------------------------+
|  Temurin     Corretto    Oracle    Liberica    Zulu     |
|  boot JDK    boot JDK    boot JDK  boot JDK   boot JDK  |
|     |            |           |         |          |     |
|     v            v           v         v          v     |
|  +---------------------------------------------------+  |
|  |  Same sources: OpenJDK jdk-25.0.5.0.3-ga          |  |
|  |  Same compiler: GCC 12                            |  |
|  |  Same flags: configure + make images              |  |
|  +---------------------------------------------------+  |
|     |            |           |         |          |     |
|     v            v           v         v          v     |
|  hash #1     hash #2     hash #3   hash #4    hash #5   |
|     |            |           |         |          |     |
|     +--------  compare  ----+---------+----------+      |
|                IDENTICAL                                |
+---------------------------------------------------------+
```

### What is a boot JDK

OpenJDK is partially written in Java. Compiling the Java sources requires
a working JDK -- the **boot JDK**. It is used to:

1. Compile JDK Java sources (java.base, javac, etc.) into bytecode
2. Run Java-based build tools

The boot JDK does **not** affect native code (libjvm.so, java binary) --
that is compiled by GCC.

### Normalization

The boot JDK leaves one trace: the `Created-By` line in
`META-INF/MANIFEST.MF` inside .jar files:

```
Created-By: 25.0.5 (Eclipse Adoptium)   <- Temurin
Created-By: 25.0.5 (Amazon.com Inc.)    <- Corretto
```

The build script normalizes this to `Created-By: OpenJDK` in all
.jar and .jmod files. After normalization, output is bytewise identical.

### The .jmod format

`.jmod` files are zip archives with a 4-byte magic header (`JM\x01\x00`)
prepended. Standard `zip` cannot update them directly. The script:

1. Strips the 4-byte header with `dd`
2. Works with the remaining zip body
3. Repacks with fixed timestamps and deterministic file order
4. Prepends the header back

### Reproducibility

For bytewise reproducibility:

- `--with-native-debug-symbols=none` -- no debug info (contains paths)
- `SOURCE_DATE_EPOCH` from `SOURCE_DATE` -- fixed timestamp for `touch`, `zip -X`
- `find | sort | zip -X` -- deterministic file order in archives
- `dpkg-deb --root-owner-group -Zxz` -- fixed owner and compression

## Sources

| Component  | Source | Version |
|------------|--------|---------|
| OpenJDK    | [github.com/openjdk/jdk25u](https://github.com/openjdk/jdk25u) | `jdk-25.0.5.0.3-ga` |
| Base image | `registry.astralinux.ru/library/astra/ubi18` | 1.8.6 |
| Boot JDKs  | Vendor download sites, see `versions/25.lock` | 5 vendors |

## Limitations

- **amd64 only**. For arm64, use arm64 boot JDKs.
- Rebuilding the builder image requires access to `registry.astralinux.ru` and the
  Astra package repository; the offline build does not.
- The .deb is packaged directly (not via dpkg-buildpackage).
- A previously installed `openjdk-21-jdk` from this project registers `javac`,
  `jar`, `javadoc` and `jshell` as slave alternatives and must be removed first.
- JDK 21 has no `versions/21.lock` yet; add it before building JDK 21.
- Upstream sources without Debian/Astra patches. For production, consider
  applying patches from [salsa.debian.org/openjdk-team/openjdk](https://salsa.debian.org/openjdk-team/openjdk).

## References

- [Reflections on Trusting Trust](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf) -- Ken Thompson, 1984
- [Diverse Double-Compilation](https://dwheeler.com/trusting-trust/) -- David A. Wheeler
- [Reproducible Builds](https://reproducible-builds.org/) -- Debian project

## License

OpenJDK sources: GPL v2 with Classpath Exception.
Build scripts: MIT.
