#!/bin/bash
# shellcheck disable=SC1091

################################################################################
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

################################################################################
#
# This script sets up the initial configuration for an (Adopt) OpenJDK Build.
# See the configure_build function and its child functions for details.
# It's sourced by the makejdk-any-platform.sh script.
#
################################################################################

set -eu

# i.e. Where we are
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=sbin/common/constants.sh
source "$SCRIPT_DIR/sbin/common/constants.sh"

# shellcheck source=sbin/common/common.sh
source "$SCRIPT_DIR/sbin/common/common.sh"

# Bring in the source signal handler
sourceSignalHandler() {
  #shellcheck source=signalhandler.sh
  source "$SCRIPT_DIR/signalhandler.sh"
}

# Parse the command line arguments
parseCommandLineArgs() {
  # Defer most of the work to the shared function in common-functions.sh
  parseConfigurationArguments "$@"

  # Check the build variant here as this is earliest point where constants.sh is loaded
  # shellcheck disable=SC2143
  if [ -z "$(echo "${BUILD_VARIANTS}" | grep -w "${BUILD_CONFIG[BUILD_VARIANT]}")" ]; then
    echo "[ERROR] ${BUILD_CONFIG[BUILD_VARIANT]} is not a recognised build variant. Valid Variants = ${BUILD_VARIANTS}"
    exit 1
  fi

  # this check is to maintain backwards compatibility and allow user to use
  # -v rather than the mandatory argument
  if [[ "${BUILD_CONFIG[OPENJDK_FOREST_NAME]}" == "" ]]; then
    if [[ $# -eq 0 ]]; then
      echo "Please provide a java version to build as an argument"
      exit 1
    fi

    while [[ $# -gt 1 ]]; do
      shift
    done

    # Now that we've processed the flags, grab the mandatory argument(s)
    setOpenJdkVersion "$1"
    setDockerVolumeSuffix "$1"
  fi
}

# Extra config for OpenJDK variants such as OpenJ9, SAP et al
# shellcheck disable=SC2153
doAnyBuildVariantOverrides() {
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_SAP}" ]]; then
    local branch="sapmachine10"
    BUILD_CONFIG[BRANCH]=${branch:-${BUILD_CONFIG[BRANCH]}}
  fi
}

# Set the working directory for this build
setWorkingDirectory() {
  if [ -z "${BUILD_CONFIG[WORKSPACE_DIR]}" ]; then
    if [[ "${BUILD_CONFIG[USE_DOCKER]}" == "true" ]]; then
      BUILD_CONFIG[WORKSPACE_DIR]="/openjdk/"
    else
      BUILD_CONFIG[WORKSPACE_DIR]="$PWD/workspace"
      mkdir -p "${BUILD_CONFIG[WORKSPACE_DIR]}" || exit
    fi
  else
    echo "Workspace dir is ${BUILD_CONFIG[WORKSPACE_DIR]}"
  fi

  echo "Working dir is ${BUILD_CONFIG[WORKING_DIR]}"
}

# shellcheck disable=SC2153
determineBuildProperties() {
  local build_type=
  local default_build_full_name=
  # From jdk12 there is no build type in the build output directory name
  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK12_CORE_VERSION}" ] ||
    [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK13_CORE_VERSION}" ] ||
    [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK14_CORE_VERSION}" ] ||
    [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK15_CORE_VERSION}" ] ||
    [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDKHEAD_CORE_VERSION}" ]; then
    build_type=normal
    default_build_full_name=${BUILD_CONFIG[OS_KERNEL_NAME]}-${BUILD_CONFIG[OS_ARCHITECTURE]}-${BUILD_CONFIG[JVM_VARIANT]}-release
  else
    default_build_full_name=${BUILD_CONFIG[OS_KERNEL_NAME]}-${BUILD_CONFIG[OS_ARCHITECTURE]}-${build_type}-${BUILD_CONFIG[JVM_VARIANT]}-release
  fi
  BUILD_CONFIG[BUILD_FULL_NAME]=${BUILD_CONFIG[BUILD_FULL_NAME]:-"$default_build_full_name"}
}

# Set variables that the `configure` command (which builds OpenJDK) will need
# shellcheck disable=SC2153
setVariablesForConfigure() {

  local openjdk_core_version=${BUILD_CONFIG[OPENJDK_CORE_VERSION]}
  # test-image, debug-image and static-libs-image targets are optional - build scripts check whether the directories exist
  local openjdk_test_image_path="test"
  local openjdk_debug_image_path="debug-image"
  local openjdk_static_libs_image_path="static-libs"

  if [ "$openjdk_core_version" == "${JDK8_CORE_VERSION}" ]; then
    local jdk_path="j2sdk-image"
    local jre_path="j2re-image"
    case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
    "darwin")
      local jdk_path="j2sdk-bundle/jdk*.jdk"
      local jre_path="j2re-bundle/jre*.jre"
      ;;
    esac
  else
    local jdk_path="jdk"
    local jre_path="jre"
    case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
    "darwin")
      local jdk_path="jdk-bundle/jdk-*.jdk"
      local jre_path="jre-bundle/jre-*.jre"
      ;;
    esac
  fi

  BUILD_CONFIG[JDK_PATH]=$jdk_path
  BUILD_CONFIG[JRE_PATH]=$jre_path
  BUILD_CONFIG[TEST_IMAGE_PATH]=$openjdk_test_image_path
  BUILD_CONFIG[DEBUG_IMAGE_PATH]=$openjdk_debug_image_path
  BUILD_CONFIG[STATIC_LIBS_IMAGE_PATH]=$openjdk_static_libs_image_path
}

# Set the repository to build from, defaults to adoptium if not set by the user
# shellcheck disable=SC2153
setRepository() {

  local suffix

  # Location of Extensions for OpenJ9 project
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]]; then
    suffix="ibmruntimes/openj9-openjdk-${BUILD_CONFIG[OPENJDK_CORE_VERSION]}"
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_SAP}" ]]; then
    # TODO need to map versions to SAP branches going forwards
    # sapmachine10 is the current branch for OpenJDK10 mainline
    # (equivalent to jdk/jdk10 on hotspot)
    suffix="SAP/SapMachine"
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_CORRETTO}" ]]; then
    suffix="corretto/corretto-${BUILD_CONFIG[OPENJDK_CORE_VERSION]:3}"
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_DRAGONWELL}" ]]; then
    suffix="alibaba/dragonwell${BUILD_CONFIG[OPENJDK_CORE_VERSION]/jdk/}"
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_FAST_STARTUP}" ]]; then
    suffix="adoptium/jdk11u-fast-startup-incubator"
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_BISHENG}" ]]; then
    suffix="openeuler-mirror/bishengjdk-${BUILD_CONFIG[OPENJDK_CORE_VERSION]:3}"
  elif [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ] && [ "${BUILD_CONFIG[OS_ARCHITECTURE]}" == "armv7l" ] && [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_TEMURIN}" ]]; then
    suffix="adoptium/aarch32-jdk8u";
  elif [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ] && [ "${BUILD_CONFIG[OS_ARCHITECTURE]}" == "armv7l" ] && [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_HOTSPOT}" ]]; then
    suffix="adoptium/aarch32-port-jdk8u";
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_TEMURIN}" ]]; then
    suffix="adoptium/${BUILD_CONFIG[OPENJDK_FOREST_NAME]}"
  else
    suffix="openjdk/${BUILD_CONFIG[OPENJDK_FOREST_NAME]}"
  fi

  local repository

  if [[ "${BUILD_CONFIG[USE_SSH]}" == "true" ]]; then
    repository="git@github.com:${suffix}"
  else
    repository="https://github.com/${suffix}"
  fi

  repository="$(echo "${repository}" | awk '{print tolower($0)}')"

  BUILD_CONFIG[REPOSITORY]="${BUILD_CONFIG[REPOSITORY]:-${repository}}"
}

# Specific architectures need to have special build settings
# shellcheck disable=SC2153
processArgumentsforSpecificArchitectures() {
  local jvm_variant=server
  local build_full_name=""
  local make_args_for_any_platform=""

  case "${BUILD_CONFIG[OS_ARCHITECTURE]}" in
  "s390x")
    if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ] && [ "${BUILD_CONFIG[BUILD_VARIANT]}" != "${BUILD_VARIANT_OPENJ9}" ]; then
      jvm_variant=zero
    else
      jvm_variant=server
    fi

    if [ "${BUILD_CONFIG[OPENJDK_FEATURE_NUMBER]}" -ge 12 ]; then
      build_full_name=linux-s390x-${jvm_variant}-release
    else
      build_full_name=linux-s390x-normal-${jvm_variant}-release
    fi

    # This is to ensure consistency with the defaults defined in setMakeArgs()
    if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
      make_args_for_any_platform="CONF=${build_full_name} DEBUG_BINARIES=true images"
    # Don't produce a JRE
    elif [ "${BUILD_CONFIG[CREATE_JRE_IMAGE]}" == "false" ]; then
      make_args_for_any_platform="CONF=${build_full_name} DEBUG_BINARIES=true product-images"
    else
      make_args_for_any_platform="CONF=${build_full_name} DEBUG_BINARIES=true product-images legacy-jre-image"
    fi
    ;;

  "ppc64le")
    jvm_variant=server

    if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK12_CORE_VERSION}" ] ||
      [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK13_CORE_VERSION}" ] ||
      [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK14_CORE_VERSION}" ] ||
      [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK15_CORE_VERSION}" ] ||
      [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDKHEAD_CORE_VERSION}" ]; then
      build_full_name=linux-ppc64-${jvm_variant}-release
    else
      build_full_name=linux-ppc64-normal-${jvm_variant}-release
    fi

    if [ "$(command -v rpm)" ]; then
      # shellcheck disable=SC1083
      BUILD_CONFIG[FREETYPE_FONT_BUILD_TYPE_PARAM]=${BUILD_CONFIG[FREETYPE_FONT_BUILD_TYPE_PARAM]:="--build=$(rpm --eval %{_host})"}
    fi
    ;;

  "armv7l")
    if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ] && isHotSpot; then
      jvm_variant=client
      make_args_for_any_platform="DEBUG_BINARIES=true images"
    elif [ "${BUILD_CONFIG[CREATE_JRE_IMAGE]}" == "false" ]; then
      # Don't produce a JRE
      jvm_variant=server,client
      make_args_for_any_platform="DEBUG_BINARIES=true images"
    else
      jvm_variant=server,client
      make_args_for_any_platform="DEBUG_BINARIES=true images legacy-jre-image"
    fi
    if [[ ${BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]:-""} != *"--with-jobs"* ]]; then
      BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]="--with-jobs=${BUILD_CONFIG[NUM_PROCESSORS]} ${BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]:-''}"
    fi
    ;;

  esac

  BUILD_CONFIG[JVM_VARIANT]=${BUILD_CONFIG[JVM_VARIANT]:-$jvm_variant}
  BUILD_CONFIG[BUILD_FULL_NAME]=${BUILD_CONFIG[BUILD_FULL_NAME]:-$build_full_name}
  BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]:-$make_args_for_any_platform}
  BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]=${BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]:-""}
}

# Different platforms have different default make commands
# shellcheck disable=SC2153
setMakeCommandForOS() {
  local make_command_name
  case "$OS_KERNEL_NAME" in
  "aix")
    make_command_name="gmake"
    ;;
  "sunos")
    make_command_name="gmake"
    ;;
  esac

  BUILD_CONFIG[MAKE_COMMAND_NAME]=${BUILD_CONFIG[MAKE_COMMAND_NAME]:-$make_command_name}
}

function configureMacFreeFont() {
  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK9_CORE_VERSION}" ] || [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
    BUILD_CONFIG[COPY_MACOSX_FREE_FONT_LIB_FOR_JDK_FLAG]="true"
    BUILD_CONFIG[COPY_MACOSX_FREE_FONT_LIB_FOR_JRE_FLAG]="true"
  fi

  echo "[debug] COPY_MACOSX_FREE_FONT_LIB_FOR_JDK_FLAG=${BUILD_CONFIG[COPY_MACOSX_FREE_FONT_LIB_FOR_JDK_FLAG]}"
  echo "[debug] COPY_MACOSX_FREE_FONT_LIB_FOR_JRE_FLAG=${BUILD_CONFIG[COPY_MACOSX_FREE_FONT_LIB_FOR_JRE_FLAG]}"
}

function setMakeArgs() {
  echo "JDK Image folder name: ${BUILD_CONFIG[JDK_PATH]}"
  echo "JRE Image folder name: ${BUILD_CONFIG[JRE_PATH]}"

  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" != "${JDK8_CORE_VERSION}" ]; then
    case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
    "darwin")
      if [ "${BUILD_CONFIG[CREATE_JRE_IMAGE]}" == "false" ]; then
        # Skip JRE
        BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]:-"product-images"}
      else
        BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]:-"product-images mac-legacy-jre-bundle"}
      fi
      ;;
    *)
      if [ "${BUILD_CONFIG[CREATE_JRE_IMAGE]}" == "false" ]; then
        # Skip JRE on JDK16+
        BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]:-"product-images"}
      else
        BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]:-"product-images legacy-jre-image"}
      fi
      ;;
    esac
    # In order to build an exploded image, no other make targets can be used
    if [ "${BUILD_CONFIG[MAKE_EXPLODED]}" == "true" ]; then
      BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=""
    fi
  else
    BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]=${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]:-"images"}
  fi
}

################################################################################

configure_build() {
  configDefaults

  # Parse the CL Args, see ${SCRIPT_DIR}/configureBuild.sh for details
  parseCommandLineArgs "$@"

  # Update the configuration with the arguments passed in, the platform etc
  setVariablesForConfigure
  setRepository
  processArgumentsforSpecificArchitectures
  setMakeCommandForOS

  determineBuildProperties
  sourceSignalHandler
  doAnyBuildVariantOverrides
  setWorkingDirectory
  configureMacFreeFont
  setMakeArgs
  setBootJdk
}
