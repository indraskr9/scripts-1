#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2018 Nathan Chancellor
#
# android-linux-stable management script


# Static logging function
function log() {
    if [[ -n ${LOGGING} ]]; then
        echo "${@}" >> "${LOG}"
    fi
}

# Quick kernel version function
function kv() {
    make CROSS_COMPILE="" kernelversion
}

# Steps to execute post 'git fm'
function post_git_fm_steps() {
    # Log our success
    log "${LOG_TAG} ${1}"
    # Don't push if we're just testing
    [[ -z ${TEST} ]] && git push
    # Make sure SKIP_BUILD gets unset
    unset SKIP_BUILD
}

# Steps to execute if merge failed
function failed_steps() {
    # Abort merge
    git ma
    # Reset back to origin
    git rh "origin/${BRANCH}"
    # Skip building if requested
    SKIP_BUILD=true
}


source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || return; pwd)/common"
source "${SCRIPTS_FOLDER}"/snippets/bk
source "${SCRIPTS_FOLDER}"/snippets/deldog
trap 'echo; die "Manually aborted!"' SIGINT SIGTERM

# Variables
ALS=${KERNEL_FOLDER}/als
REPOS_318=( "marlin" "msm-3.18" "op3" "tissot" )
REPOS_44=( "msm-4.4" "nash" "op5" "sagit" "wahoo" "whyred" )
REPOS_49=( "msm-4.9" "op6" "polaris" )

# Parse parameters
PARAMS="${*}"
while [[ ${#} -ge 1 ]]; do
    case ${1} in
        # Build after merging
        "-b"|"--build")
            BUILD=true ;;

        "-i"|"--initialize")
            INIT=true ;;

        # Log merge and build results
        "-l"|"--log")
            LOGGING=true ;;

        # Merge from stable-queue
        "-q"|"--queue")
            ALS_PARAMS+=( "-q" )
            QUEUE=true
            TEST=true ;;

        # Subset of repos (implies -v has been set)
        "-R"|"--repos")
            shift && enforce_value "${@}"
            read -r -a REPOS_PARAM <<< "${1}" ;;

        # Resolve conflicts with stable-patches commands
        "-r"|"--resolve-conflicts")
            RESOLVE=true ;;

        # Merge from linux-stable-rc
        "-rc"|"--release-candidate")
            ALS_PARAMS+=( "-r" )
            RC=true
            TEST=true ;;

        # Versions to merge, separated by commas
        "-v"|"--versions")
            shift && enforce_value "${@}"
            # SC2076: Don't quote rhs of =~, it'll match literally rather than as a regex.
            # shellcheck disable=SC2076
            [[ ${1} =~ "3.18" || ${1} =~ "4.4" || ${1} =~ "4.9" ]] || die "Invalid version specified!"
            IFS="," read -r -a VERSIONS <<< "${1}" ;;
    esac
    shift
done

# If no versions were specified, assume we want all
[[ -z ${VERSIONS} ]] && VERSIONS=( "3.18" "4.4" "4.9" )

# If '-rc' or '-q' weren't specified, we are doing an actual stable release, meaning RESOLVE=true
[[ -z ${TEST} ]] && RESOLVE=true

# Start with a clean log
[[ -n ${LOGGING} ]] && rm -rf "${LOG}"

# If initialization was requested
if [[ -n ${INIT} ]]; then
    mkdir -p "${ALS}"; cd "${ALS}" || die "${ALS} creation failed!"

    for ITEM in "${REPOS_318[@]}" "${REPOS_44[@]}" "${REPOS_49[@]}"; do
        git clone "git@github.com:android-linux-stable/${ITEM}.git" || die "Could not clone ${ITEM}!"
        case ${ITEM} in
            "marlin"|"wahoo")
                REMOTES=( "upstream:https://android.googlesource.com/kernel/msm" ) ;;
            "msm-3.18"|"msm-4.4"|"msm-4.9")
                REMOTES=( "upstream:https://source.codeaurora.org/quic/la/kernel/${ITEM}" ) ;;
            "nash")
                REMOTES=( "upstream:https://github.com/MotorolaMobilityLLC/kernel-msm" ) ;;
            "op3")
                REMOTES=( "LineageOS:https://github.com/LineageOS/android_kernel_oneplus_msm8996"
                          "omni:https://github.com/omnirom/android_kernel_oneplus_msm8996"
                          "upstream:https://github.com/OnePlusOSS/android_kernel_oneplus_msm8996" ) ;;
            "op5")
                REMOTES=( "LineageOS:https://github.com/LineageOS/android_kernel_oneplus_msm8998"
                          "omni:https://github.com/omnirom/android_kernel_oneplus_msm8998"
                          "upstream:https://github.com/OnePlusOSS/android_kernel_oneplus_msm8998" ) ;;
            "op6")
                REMOTES=( "LineageOS:https://github.com/LineageOS/android_kernel_oneplus_sdm845"
                          "omni:https://github.com/omnirom/android_kernel_oneplus_sdm845"
                          "upstream:https://github.com/OnePlusOSS/android_kernel_oneplus_sdm845" ) ;;
            "polaris"|"sagit"|"tissot"|"whyred")
                REMOTES=( "upstream:https://github.com/MiCode/Xiaomi_Kernel_OpenSource" ) ;;
        esac
        for REMOTE in "${REMOTES[@]}"; do
            git -C "${ITEM}" remote add "${REMOTE%%:*}" "${REMOTE#*:}"
        done
        git -C "${ITEM}" remote update
    done
fi

# Iterate through all versions
for VERSION in "${VERSIONS[@]}"; do
    # Set up repos variable based on version if REPOS is not set
    if [[ -z "${REPOS_PARAM[*]}" ]]; then
        case ${VERSION} in
            "3.18") REPOS=( "${REPOS_318[@]}" ) ;;
            "4.4") REPOS=( "${REPOS_44[@]}" ) ;;
            "4.9") REPOS=( "${REPOS_49[@]}" ) ;;
        esac
    else
        REPOS=( "${REPOS_PARAM[@]}" )
    fi

    # Iterate through the repos
    for REPO in "${REPOS[@]}"; do
        # Map all of the branches of the repo to an upstream remote (if relevant)
        case ${REPO} in
            "marlin") BRANCHES=( "android-msm-marlin-3.18" ) ;;
            "msm-3.18") BRANCHES=( "kernel.lnx.3.18.r33-rel" ) ;;
            "msm-4.4") BRANCHES=( "kernel.lnx.4.4.r27-rel" "kernel.lnx.4.4.r35-rel" ) ;;
            "msm-4.9") BRANCHES=( "kernel.lnx.4.9.r7-rel" ) ;;
            "nash") BRANCHES=( "oreo-8.0.0-release-nash:upstream" ) ;;
            "op3") BRANCHES=( "android-8.1:omni" "lineage-15.1:LineageOS" "oneplus/QC8996_O_8.0.0:upstream" ) ;;
            "op5") BRANCHES=( "android-8.1:omni" "lineage-15.1" "oneplus/QC8998_O_8.1:upstream" "oneplus/QC8998_O_8.1_Beta:upstream" ) ;;
            "op6") BRANCHES=( "android-8.1:omni" "lineage-15.1:LineageOS" "oneplus/SDM845_O_8.1:upstream" ) ;;
            "polaris") BRANCHES=( "polaris-o-oss:upstream" ) ;;
            "sagit") BRANCHES=( "sagit-o-oss:upstream" ) ;;
            "tissot") BRANCHES=( "tissot-o-oss-8.1:upstream" ) ;;
            "wahoo") BRANCHES=( "android-msm-wahoo-4.4" ) ;;
            "whyred") BRANCHES=( "whyred-o-oss:upstream" ) ;;
        esac

        # Move into the repo, unless it doesn't exist
        if ! cd "${ALS}/${REPO}"; then
            warn "${ALS}/${REPO} doesn't exist, skipping!"
            log "${REPO}: Skipped\n"
            continue
        fi

        # Iterate through all branches
        for BRANCH in "${BRANCHES[@]}"; do
            REMOTE=${BRANCH##*:}
            BRANCH=${BRANCH%%:*}
            LOG_TAG="${REPO} | ${BRANCH} |"

            header "${REPO} - ${BRANCH}"

            # Checkout the branch
            if ! git ch "${BRANCH}"; then
                # If we get an error, it's because git can't resolve which branch we want
                git ch -b "${BRANCH}" "origin/${BRANCH}" || die "Branch doesn't exist!"
            fi

            # Make sure we have a clean tree
            git fetch origin
            git rh "origin/${BRANCH}"

            # If there is an upstream remote (REMOTE and BRANCH aren't the same), merge it if the main merge is not an RC or queue merge
            if [[ "${REMOTE}" != "${BRANCH}" && -z "${ALS_PARAMS[*]}" ]]; then
                git fetch "${REMOTE}"
                git ml --no-edit "${REMOTE}/${BRANCH}" || die "${LOG_TAG} ${REMOTE}/${BRANCH} merge error! Please resolve then re-run the script!"
            fi

            # Cache kernel version. This needs to be done before doing a merge in case Makefile conflicts...
            KVER=$(kv)
            MAJOR_VER=${KVER%.*}
            if [[ -n ${QUEUE} ]]; then
                COMMANDS_BRANCH=stable-queue/queue-${MAJOR_VER}
            else
                COMMANDS_BRANCH=linux-stable${RC:+"-rc"}/linux-${MAJOR_VER}.y
            fi
            LOG_TAG="${LOG_TAG} ${COMMANDS_BRANCH} |"

            # Merge the update, logging success and pushing as necessary
            if merge-stable "${ALS_PARAMS[@]}"; then
                # Show merged kernel version in log
                post_git_fm_steps "Merge successful: $(kv)"
            else
                # Resolve if requested
                if [[ -n ${RESOLVE} ]]; then
                    # Get the appropriate resolution command filename (static mapping because it is not uniform)
                    case "${REPO}:${BRANCH}" in
                        "marlin"*|"msm"*|"polaris"*|"sagit"*|"tissot"*|"wahoo"*|"whyred"*) COMMANDS="${REPO}-commands" ;;
                        "nash"*) COMMANDS="nash-oreo-8.0.0-commands" ;;
                        "op3:oneplus/QC8996_O_8.0.0") COMMANDS="${REPO}-8.0.0-commands" ;;
                        "op5:oneplus/QC8998_O_8.1"|"op6:oneplus/SDM845_O_8.1") COMMANDS="${REPO}-O_8.1-commands" ;;
                        "op5:oneplus/QC8998_O_8.1_Beta") COMMANDS="${REPO}-O_8.1_Beta-commands" ;;
                        "op"*) COMMANDS="${REPO}-${BRANCH}-commands" ;;
                    esac

                    # Arbitrarily assume that we're only merging one version ahead
                    KVER=${MAJOR_VER}.$((${KVER##*.} + 1))

                    # If a command file is found, execute it
                    COMMANDS=${REPO_FOLDER}/sp/${KVER}/${COMMANDS}
                    if [[ -f ${COMMANDS} ]]; then
                        if bash "${COMMANDS}" "${COMMANDS_BRANCH}"; then
                            # Show merged kernel version in log
                            post_git_fm_steps "Merge failed but resolution was successful: $(kv)"
                        else
                            log "${LOG_TAG} Merge failed, even after attempting resolution!"
                            failed_steps
                        fi
                    # If no command file was found, something is messed up
                    else
                        log "${LOG_TAG} Resolution was requested but no resolution file was found!"
                    fi
                # Log failure otherwise
                else
                    log "${LOG_TAG} Merge failed!"
                    log "${LOG_TAG} Conflicts:"
                    log "$(git cf)"
                    failed_steps
                fi
            fi

            # Build if requested and not Nash
            if [[ -n ${BUILD} && -z ${SKIP_BUILD} ]]; then
                # msm-3.18 has two defconfigs to build: msm-perf_defconfig and msm8937-perf_defconfig
                [[ ${REPO} = "msm-3.18" ]] && BK_COMMANDS=( "bk" "bk -d msm8937-perf_defconfig" ) || BK_COMMANDS=( "bk" )

                for BK_COMMAND in "${BK_COMMANDS[@]}"; do
                    if ${BK_COMMAND}; then
                        # Show kernel version in log
                        log "${LOG_TAG} Build successful: $(kv)$(cd out || return; ../scripts/setlocalversion ..)"
                    else
                        # Add command for quick reproduction of build failure
                        log "${LOG_TAG} Build failed: ( cd ${ALS}/${REPO}; ${BK_COMMAND} )"
                    fi
                done
            fi
            log
        done
    done
    log; log; log
done

if [[ -n ${LOGGING} ]]; then
    URL=$(deldog "${LOG}")

    clear
    echo
    echo "${BOLD}ALS merge results:${RST} ${URL}"
    echo
    tg_msg "ALS merge results (\`$(basename "${0}") ${PARAMS}\`): ${URL}"
fi

exit 0
