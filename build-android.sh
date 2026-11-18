#!/bin/sh
# build-android.sh [configure.py's options]: the Android build and its APK
# (build-env.sh), Gradle run with JDK 17 whatever the system's default Java is.
# It asks whether this is a beta build: one is the app com.halo.decomp.beta,
# "Halo Beta", installed beside com.halo.decomp with its own data. HALO_BETA=1
# or HALO_BETA=0 answers without asking (no terminal: not a beta).
set -e
. "$(dirname "$(readlink -f "$0")")/build-env.sh"

# the guest's clang, the host library's CMake, Gradle's JDK 17
pacman_needed clang lld llvm cmake jdk17-openjdk
# the NDK (r30, in ANDROID_NDK_HOME), sdkmanager, adb, the build tools
aur_needed android-ndk android-sdk-cmdline-tools-latest android-sdk-platform-tools \
	android-sdk-build-tools

# Not packaged: the platform and build tools Gradle asks for, from
# sdkmanager (as root: /opt/android-sdk is root's), one line each:
#   sudo /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk "platforms;android-35"
#   sudo /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk "build-tools;36.0.0"

if [ -z "$HALO_BETA" ]; then
	HALO_BETA=0
	if [ -t 0 ]; then
		printf 'Is this a beta build (com.halo.decomp.beta, "Halo Beta")? [y/N] '
		read -r answer
		case "$answer" in
			[yY]|[yY][eE][sS]) HALO_BETA=1 ;;
		esac
	fi
fi
if [ "$HALO_BETA" = 1 ]; then
	export ORG_GRADLE_PROJECT_haloAppIdSuffix=.beta
	echo "Building the beta: com.halo.decomp.beta"
else
	export ORG_GRADLE_PROJECT_haloAppIdSuffix=
	echo "Building com.halo.decomp"
fi

configure "$@"
ninja android
# (the APK made again when the answer differs from the last build's: ninja
# sees no other change)
apk=port/android/app/build/outputs/apk/debug/app-debug.apk
last=port/android/app/build/halo_app_id_suffix
if [ "$(cat "$last" 2>/dev/null)" != "$ORG_GRADLE_PROJECT_haloAppIdSuffix" ]; then
	rm -f "$apk"
fi
JAVA_HOME=$JAVA_17_HOME PATH="$JAVA_17_HOME/bin:$PATH" ninja android_apk
mkdir -p "$(dirname "$last")"
printf '%s' "$ORG_GRADLE_PROJECT_haloAppIdSuffix" > "$last"
echo "APK: $GULCHCE_DIR/$apk"
