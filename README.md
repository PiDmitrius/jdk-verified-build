# OpenJDK Verified Build

Build OpenJDK from upstream sources and check it via
**Diverse Multi-Compilation**.

Each JDK version has its own file in [`versions/`](versions); parameters common
to all of them are in [`versions.env`](versions.env).
Select the version with `JDK_MAJOR=<major>`; the default is the newest `versions/<major>.lock`.

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

| Vendor   | Identifier | Organization       |
|----------|------------|--------------------|
| Temurin  | `tem`      | Eclipse Adoptium   |
| Corretto | `amzn`     | Amazon             |
| Oracle   | `oracle`   | Oracle Corporation |
| Liberica | `librca`   | BellSoft           |
| Zulu     | `zulu`     | Azul Systems       |

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

All files of the JDK image are bytewise identical: native binaries, CDS
archives, the modules image, .jar archives and .jmod modules. The .deb is built
by one more compilation, and its image is checked against the same hashes.

## Usage

There are two ways to build, both verified against `expected/<major>`.

**Online**, from a checkout. `deps.sh` checks the source and boot JDK archives
against `versions/<major>.lock` and downloads missing or changed inputs into
`inputs/<major>/`. It builds the builder image from `Dockerfile` if the image
archive is absent. `run.sh` then builds without network.

```bash
JDK_MAJOR=21 ./deps.sh
JDK_MAJOR=21 ./verify.sh results
```

If the builder package list changes, use the same fresh `INPUTS` directory
for `deps.sh` and `verify.sh` or `kit.sh`.

**Offline**, from a kit prepared locally.

`./verify.sh` compares all five boot JDKs. `ONE_VENDOR=tem ./verify.sh results`
builds with one boot JDK: the comparison between vendors is already fixed in
`expected/<major>`, so a match there gives the same result in a fraction of the time.

### Offline kit

`kit.sh` bundles the builder image, sources, boot JDKs, build recipe and
expected hashes. Prepare a kit from a checkout with network access.

```bash
major=21
JDK_MAJOR=$major ./deps.sh
JDK_MAJOR=$major ./kit.sh "dist/jdk-verified-$major-kit.tar"
```

Reproduce on an amd64 machine with `tar` and Docker. Allow disk space for the
unpacked inputs and Docker build data.

```bash
major=21
tar xf "jdk-verified-$major-kit.tar"
cd "jdk-verified-$major"
./verify.sh results
```

`versions/<major>.lock` holds two hashes per input: of the `.tar.gz` as published
and of the unpacked `.tar` used by the build. To check the kit against the
vendors, with network, after `./verify.sh` has unpacked the inputs:

```bash
major=21
mkdir vendor && cp "inputs/$major/docker-builder.tar.gz" vendor/
INPUTS=vendor ./deps.sh
```

`run.sh` checks the builder image against `versions/<major>.packages` in both
modes.

### Output

```
results/
  openjdk-<major>-jdk_<version>-1_amd64.deb  # verified package
  hashes-*.txt                             # SHA256 of all files
  native-*.txt                             # SHA256 of native binaries
```

### Install on Astra Linux

The current [GitHub releases](https://github.com/PiDmitrius/jdk-verified-build/releases)
for JDK 21 and 25 each provide an amd64 `.deb` and `SHA256SUMS`. Download both
files into the same directory. Run the commands there, substituting the major
version and package version from the asset name.

```bash
sha256sum -c SHA256SUMS &&
  sudo dpkg -i "./openjdk-<major>-jdk_<version>-1_amd64.deb" &&
  "/usr/lib/jvm/java-<major>-openjdk-amd64/bin/java" -version
```

For a local build, install the verified package from `results/`.

Installs JDK to `/usr/lib/jvm/java-<major>-openjdk-amd64/` and registers
`java`, `javac`, `jar`, `javadoc`, `jshell` via `update-alternatives`.

## Configuration

Version parameters in `versions/<major>.env`:

```bash
JDK_TAG="jdk-<version>-ga"
VENDORS=( "<boot-version>-tem" ... )
SOURCE_DATE="<YYYY-MM-DD>"
```

Download locations and SHA-256 are in `versions/<major>.lock`, package versions in
`versions/<major>.packages`. The base image is pinned by digest in `Dockerfile`.

## How it works

### Architecture

```
Astra Linux container
+---------------------------------------------------------+
|  Temurin     Corretto    Oracle    Liberica    Zulu     |
|  boot JDK    boot JDK    boot JDK  boot JDK   boot JDK  |
|     |            |           |         |          |     |
|     v            v           v         v          v     |
|  +---------------------------------------------------+  |
|  |  Same sources: OpenJDK jdk-<version>-ga           |  |
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
Created-By: <version> (Eclipse Adoptium)
Created-By: <version> (Amazon.com Inc.)
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

Source tags and boot JDK versions are in [`versions/`](versions). The source and
boot JDK archives are pinned by URL and SHA-256 in `versions/<major>.lock`.
The Astra Linux base image digest is pinned in [`Dockerfile`](Dockerfile).

## Limitations

- **amd64 only**. For arm64, use arm64 boot JDKs.
- Rebuilding the builder image requires access to `registry.astralinux.ru` and the
  Astra package repository; the offline build does not.
- The .deb is packaged directly (not via dpkg-buildpackage).
- Upstream sources without Debian/Astra patches. For production, consider
  applying patches from [salsa.debian.org/openjdk-team/openjdk](https://salsa.debian.org/openjdk-team/openjdk).

## References

- [Reflections on Trusting Trust](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf) -- Ken Thompson, 1984
- [Diverse Double-Compilation](https://dwheeler.com/trusting-trust/) -- David A. Wheeler
- [Reproducible Builds](https://reproducible-builds.org/) -- Debian project

## License

OpenJDK sources: GPL v2 with Classpath Exception.
Build scripts: MIT.
