# OpenJDK Verified Build

Build OpenJDK from upstream sources with backdoor verification via
**Diverse Multi-Compilation**.

All versions and parameters are in [`versions.env`](versions.env).
To build a different JDK version, edit that single file.

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

| Vendor   | Identifier       | Organization       |
|----------|------------------|--------------------|
| Temurin  | `21.0.10-tem`    | Eclipse Adoptium   |
| Corretto | `21.0.10-amzn`   | Amazon             |
| Oracle   | `21.0.10-oracle` | Oracle Corporation |
| Liberica | `21.0.10-librca` | BellSoft           |
| Zulu     | `21.0.10-zulu`   | Azul Systems       |

If all 5 produce **bytewise identical** output, none of them contains a
trojan compiler backdoor. The probability of the same backdoor in 5
independent vendors is effectively zero.

## Result

```
-- Comparison (reference: tem) --

  amzn = tem
  oracle = tem
  librca = tem
  zulu = tem

-- .deb bytewise --
  amzn .deb IDENTICAL
  oracle .deb IDENTICAL
  librca .deb IDENTICAL
  zulu .deb IDENTICAL

RESULT: ALL 5 VENDORS IDENTICAL
```

All 323 files bytewise identical: native binaries, bytecode, .jar archives,
.jmod modules, and the .deb package itself.

## Usage

### Build the Docker image

```bash
docker build -t jdk-verified .
```

Image size: ~7 GB (Astra base + GCC + 5 boot JDKs + OpenJDK sources).

### Run verification

```bash
mkdir results
docker run --rm -v $(pwd)/results:/results jdk-verified
```

Time: ~30 minutes on a 4-core machine (5 sequential builds + normalization).

### Output

```
results/
  openjdk-21-jdk_21.0.10-1_amd64_tem.deb     # .deb per vendor
  openjdk-21-jdk_21.0.10-1_amd64_amzn.deb    # (all bytewise identical)
  openjdk-21-jdk_21.0.10-1_amd64_oracle.deb
  openjdk-21-jdk_21.0.10-1_amd64_librca.deb
  openjdk-21-jdk_21.0.10-1_amd64_zulu.deb
  hashes-*.txt                                 # SHA256 of all files
  native-*.txt                                 # SHA256 of native binaries
```

### Install on Astra Linux

```bash
sudo dpkg -i results/openjdk-21-jdk_21.0.10-1_amd64_tem.deb
java -version
```

Installs JDK to `/usr/lib/jvm/java-21-openjdk-amd64/` and registers
`java`, `javac`, `jar`, `javadoc`, `jshell` via `update-alternatives`.

## Configuration

All parameters in [`versions.env`](versions.env):

```bash
# To build a different version, edit versions.env:
JDK_MAJOR=17
JDK_TAG="jdk-17.0.13-ga"
JDK_REPO="https://github.com/openjdk/jdk17u"
BOOT_JDK_VERSION="17.0.13"
```

No hardcoded versions in `Dockerfile` or `build.sh`.

## How it works

### Architecture

```
Astra Linux 1.8 (Debian 12) container
+-------------------------------------------------------+
|  Temurin     Corretto    Oracle    Liberica    Zulu    |
|  boot JDK    boot JDK    boot JDK  boot JDK   boot JDK|
|     |            |           |         |          |    |
|     v            v           v         v          v    |
|  +---------------------------------------------------+|
|  |  Same sources: OpenJDK jdk-21.0.10-ga             ||
|  |  Same compiler: GCC 12                            ||
|  |  Same flags: configure + make images              ||
|  +---------------------------------------------------+|
|     |            |           |         |          |    |
|     v            v           v         v          v    |
|  .deb #1     .deb #2     .deb #3   .deb #4    .deb #5 |
|     |            |           |         |          |    |
|     +--------  cmp -s  ------+---------+----------+    |
|                IDENTICAL                               |
+-------------------------------------------------------+
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
Created-By: 21.0.10 (Eclipse Adoptium)   <- Temurin
Created-By: 21.0.10 (Amazon.com Inc.)    <- Corretto
```

The build script normalizes this to `Created-By: 21.0.10 (OpenJDK)` in all
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
- `SOURCE_DATE_EPOCH=0` -- fixed timestamp for `touch`, `zip -X`
- `find | sort | zip -X` -- deterministic file order in archives
- `dpkg-deb --root-owner-group -Zxz` -- fixed owner and compression

## Sources

| Component  | Source | Version |
|------------|--------|---------|
| OpenJDK    | [github.com/openjdk/jdk21u](https://github.com/openjdk/jdk21u) | `jdk-21.0.10-ga` |
| Base image | `registry.astralinux.ru/library/astra/ubi18` | 1.8.5 |
| Boot JDKs  | [SDKMAN](https://sdkman.io/) | 5 vendors x 21.0.10 |

## Limitations

- **amd64 only**. For arm64, use arm64 boot JDKs.
- Astra base image requires access to `registry.astralinux.ru`.
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
