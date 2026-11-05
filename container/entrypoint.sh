#!/bin/bash
set -e

# Quick function to generate a timestamp
timestamp () {
  date +"%Y-%m-%d %H:%M:%S,%3N"
}

# Function to handle shutdown
shutdown () {
    echo ""
    echo "$(timestamp) INFO: Recieved SIGTERM, shutting down gracefully"
    supervisorctl stop all
}

# Set our trap for sigterm
trap 'shutdown' TERM

# Set vars established during image build
IMAGE_VERSION=$(cat "${VINTAGE_STORY_PATH}/image_version")
MAINTAINER=$(cat "${VINTAGE_STORY_PATH}/image_maintainer")
EXPECTED_FS_PERMS=$(cat "${VINTAGE_STORY_PATH}/expected_filesystem_permissions")

# Optional Stratum server kernel
STRATUM_ENABLED="${STRATUM_ENABLED:-false}"
STRATUM_VERSION="${STRATUM_VERSION:-}"
STRATUM_PATH="${STRATUM_PATH:-${VINTAGE_STORY_PATH}/stratum}"
STRATUM_ARGS="${STRATUM_ARGS:-}"
STRATUM_TELEMETRY="${STRATUM_TELEMETRY:-false}"

echo "$(timestamp) INFO: Launching Vintage Story dedicatged server image ${IMAGE_VERSION} by ${MAINTAINER}"

# Check for proper filesystem permissions
echo "$(timestamp) INFO: Validating data directory filesystem permissions"
if ! touch "${VINTAGE_STORY_PATH}/data/test"; then
    echo ""
    echo "$(timestamp) ERROR: The ownership of ${VINTAGE_STORY_PATH}/data is not correct and the server will not be able to save..."
    echo "the directory that you are mounting into the container needs to be owned by ${EXPECTED_FS_PERMS}"
    echo "from your container host attempt the following command 'sudo chown -R ${EXPECTED_FS_PERMS} /your/vintage_story/data/directory'"
    echo ""
    exit 1
fi

rm "${VINTAGE_STORY_PATH}/data/test"

# ---------------------------------------------------------------------------
# Stratum kernel bootstrap
#
# Stratum is a server-side fork of Vintage Story. It ships as a launcher that
# pulls the matching official server archive, verifies it and lays its patched
# assemblies on top of that base. Running the vanilla VintagestoryServer.dll
# against patched libraries does not work, so the launcher itself becomes the
# server process.
#
# Everything the launcher needs is kept in STRATUM_PATH so it can live on its
# own volume: the volume survives container re-creation and host migrations,
# and the base install is only downloaded once per Stratum version.
# ---------------------------------------------------------------------------
stratum_arch () {
    case "$(uname -m)" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64)  echo "x64" ;;
        *)             echo "x64" ;;
    esac
}

install_stratum () {
    local arch zip url installed
    arch="$(stratum_arch)"
    zip="stratum-${STRATUM_VERSION}-linux-${arch}.zip"
    url="https://github.com/StratumServer/Stratum/releases/download/v${STRATUM_VERSION}/${zip}"
    installed="$(cat "${STRATUM_PATH}/.stratum-version" 2>/dev/null || true)"

    if [ "${installed}" = "${STRATUM_VERSION}" ] && [ -x "${STRATUM_PATH}/StratumServer" ]; then
        echo "$(timestamp) INFO: Stratum ${STRATUM_VERSION} already installed at ${STRATUM_PATH}"
        return
    fi

    echo "$(timestamp) INFO: Installing Stratum ${STRATUM_VERSION} (linux-${arch})"
    wget -q -O "/tmp/${zip}" "${url}"
    unzip -oq "/tmp/${zip}" -d "${STRATUM_PATH}"
    rm -f "/tmp/${zip}"
    chmod +x "${STRATUM_PATH}/StratumServer"
    # A different kernel revision always needs a freshly prepared base.
    rm -f "${STRATUM_PATH}/.stratum-base"
    echo "${STRATUM_VERSION}" > "${STRATUM_PATH}/.stratum-version"
    echo "$(timestamp) INFO: Stratum ${STRATUM_VERSION} installed successfully"
}

prepare_stratum () {
    local base
    base="$(cat "${STRATUM_PATH}/.stratum-base" 2>/dev/null || true)"

    if [ -n "${base}" ] && [ "${base}" != "${GAME_VERSION}" ]; then
        echo "$(timestamp) INFO: Stratum base is ${base} but GAME_VERSION is ${GAME_VERSION}, re-preparing"
        rm -f "${STRATUM_PATH}/.stratum-base"
        base=""
    fi

    if [ -n "${base}" ]; then
        echo "$(timestamp) INFO: Stratum base install for ${base} already prepared"
        return
    fi

    echo "$(timestamp) INFO: Preparing Stratum base install for Vintage Story ${GAME_VERSION} (downloads the official server archive, first run only)"
    if ! ( cd "${STRATUM_PATH}" && DOTNET_ROOT="${DOTNET_PATH}" ./StratumServer --stratum-prepare-only --stratum-no-banner ); then
        echo ""
        echo "$(timestamp) ERROR: Stratum base install failed. The first start needs network access to cdn.vintagestory.at"
        echo "$(timestamp) ERROR: and github.com. Data directory and savegame were not modified."
        echo ""
        exit 1
    fi
    echo "$(timestamp) INFO: Stratum base install complete ($(cat "${STRATUM_PATH}/.stratum-base" 2>/dev/null || echo unknown))"
}

# Stratum ships with anonymous usage reporting and an update checker enabled.
# A server image should not phone home unless the operator asks for it, so the
# first start seeds a partial config with both switched off. Stratum fills in
# the remaining fields with defaults and rewrites the file in full, which means
# an existing config is never overwritten here.
seed_stratum_config () {
    local config="${VINTAGE_STORY_PATH}/data/stratum.json"

    if [ -f "${config}" ]; then
        echo "$(timestamp) INFO: Found existing Stratum config at ${config}"
        return
    fi

    if [ "${STRATUM_TELEMETRY}" = "true" ]; then
        echo "$(timestamp) INFO: STRATUM_TELEMETRY is true, leaving Stratum statistics reporting at default"
        return
    fi

    echo "$(timestamp) INFO: Seeding ${config} with anonymous stats reporting and update checking disabled"
    cat > "${config}" <<'JSON'
{
  "ServerStats": { "Enabled": false },
  "UpdateChecker": { "Enabled": false }
}
JSON
}

if [ "${STRATUM_ENABLED}" = "true" ]; then
    echo "$(timestamp) INFO: Stratum kernel requested, version ${STRATUM_VERSION:-<unset>}"

    if [ -z "${STRATUM_VERSION}" ]; then
        echo ""
        echo "$(timestamp) ERROR: STRATUM_ENABLED is true but STRATUM_VERSION is empty."
        echo "$(timestamp) ERROR: Set STRATUM_VERSION to a release tag such as '1.22.7-stratum.2' from"
        echo "$(timestamp) ERROR: https://github.com/StratumServer/Stratum/releases"
        echo ""
        exit 1
    fi

    # Stratum releases are tied to one exact Vintage Story version.
    case "${STRATUM_VERSION}" in
        "${GAME_VERSION}"-stratum.*) ;;
        *)
            echo ""
            echo "$(timestamp) ERROR: Stratum ${STRATUM_VERSION} is not built for GAME_VERSION ${GAME_VERSION}."
            echo "$(timestamp) ERROR: Set GAME_VERSION to the version the Stratum release was built against"
            echo "$(timestamp) ERROR: (the part before '-stratum.' in ${STRATUM_VERSION})."
            echo ""
            exit 1
            ;;
    esac

    mkdir -p "${STRATUM_PATH}"
    echo "$(timestamp) INFO: Validating Stratum directory filesystem permissions"
    if ! touch "${STRATUM_PATH}/.write-test"; then
        echo ""
        echo "$(timestamp) ERROR: ${STRATUM_PATH} is not writable by the container."
        echo "$(timestamp) ERROR: The directory mounted there needs to be owned by ${EXPECTED_FS_PERMS}, for example"
        echo "$(timestamp) ERROR: 'sudo chown -R ${EXPECTED_FS_PERMS} /your/vintage_story/stratum/directory'"
        echo ""
        exit 1
    fi
    rm -f "${STRATUM_PATH}/.write-test"

    install_stratum
    prepare_stratum
    seed_stratum_config

    SERVER_PROGRAM_COMMAND="${STRATUM_PATH}/StratumServer --dataPath \"${VINTAGE_STORY_PATH}/data\" ${STRATUM_ARGS}"
    SERVER_PROGRAM_DIRECTORY="${STRATUM_PATH}"
    SERVER_PROGRAM_ENVIRONMENT="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${DOTNET_PATH},DOTNET_ROOT=${DOTNET_PATH}"
    echo "$(timestamp) INFO: Server process will run the Stratum launcher, vanilla install is not used"
else
    # Get Vintage Story server binaries
    if ! [ -f "${VINTAGE_STORY_PATH}/server/VERSION" ]; then
        echo "$(timestamp) INFO: Downloading Vintage Story server version ${GAME_VERSION} from ${GAME_BRANCH}"
        wget https://cdn.vintagestory.at/gamefiles/${GAME_BRANCH,,}/vs_server_linux-x64_${GAME_VERSION}.tar.gz
        tar xzf "vs_server_linux-x64_${GAME_VERSION}.tar.gz" -C "${VINTAGE_STORY_PATH}/server"
        echo "${GAME_VERSION}" > "${VINTAGE_STORY_PATH}/server/VERSION"
        rm -f "vs_server_linux-x64_${GAME_VERSION}.tar.gz"
        echo "$(timestamp) INFO: Vintage Story server version ${GAME_VERSION} from ${GAME_BRANCH} installed successfully"
    elif [ "$(cat "${VINTAGE_STORY_PATH}/server/VERSION")" != "$GAME_VERSION" ]; then
        echo "$(timestamp) INFO: Current Vintage Story server version does not match version ${GAME_VERSION}, updating"
        echo "$(timestamp) INFO: Cleaning up previous Vintage Story installation..."
        rm -rf "${VINTAGE_STORY_PATH}/server"
        wget https://cdn.vintagestory.at/gamefiles/${GAME_BRANCH,,}/vs_server_linux-x64_${GAME_VERSION}.tar.gz
        tar xzf "vs_server_linux-x64_${GAME_VERSION}.tar.gz" -C "${VINTAGE_STORY_PATH}/server"
        echo "${GAME_VERSION}" > "${VINTAGE_STORY_PATH}/server/VERSION"
        rm -f "vs_server_linux-x64_${GAME_VERSION}.tar.gz"
        echo "$(timestamp) INFO: Vintage Story server upgraded to version ${GAME_BRANCH}/${GAME_VERSION} successfully"
    else
        echo "$(timestamp) INFO: Vintage Story server version ${GAME_VERSION} already present"
    fi

    SERVER_PROGRAM_COMMAND="dotnet \"${VINTAGE_STORY_PATH}/server/VintagestoryServer.dll\" --dataPath \"${VINTAGE_STORY_PATH}/data\""
    SERVER_PROGRAM_DIRECTORY="${VINTAGE_STORY_PATH}"
    SERVER_PROGRAM_ENVIRONMENT="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${DOTNET_PATH}"
fi

# Supervisord program definition. It is generated at runtime so the same image
# can run either the vanilla server or the Stratum launcher, and so a kernel
# switch is a single environment variable change instead of an image rebuild.
cat > "${VINTAGE_STORY_PATH}/program-vintagestory.conf" <<EOF
[program:vintagestory]
command=${SERVER_PROGRAM_COMMAND}
directory=${SERVER_PROGRAM_DIRECTORY}
autostart=true
autorestart=true
startsecs=10
startretries=20
environment=${SERVER_PROGRAM_ENVIRONMENT}
user=vintagestory
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# Set backup schedule
echo "$(timestamp) INFO: Setting backup CRON schedule as ${BACKUP_CRON_SCHEDULE}"
echo "${BACKUP_CRON_SCHEDULE} ${VINTAGE_STORY_PATH}/backup.sh" > "${VINTAGE_STORY_PATH}/backup_crontab"

# Check if we need to build a serverconfig.json file
# If we are running in Kubernetes this isn't used as we just expect a ConfigMap
if [ ! -f "${VINTAGE_STORY_PATH}/data/serverconfig.json" ]; then
    echo "$(timestamp) INFO: serverconfig.json not found at ${VINTAGE_STORY_PATH}/data/serverconfig.json"
    echo "$(timestamp) INFO: Generating new serverconfig.json"
    "${VINTAGE_STORY_PATH}/build_serverconfig.sh"
elif [ "${REGENERATE_CONFIG}" = "true" ]; then
    echo "$(timestamp) INFO: REGENERATE_CONFIG is true, regenerating serverconfig.json"
    "${VINTAGE_STORY_PATH}/build_serverconfig.sh"
else
    echo "$(timestamp) INFO: Found serverconfig.json at ${VINTAGE_STORY_PATH}/data/serverconfig.json"
fi

# Start Supervisor to manager VintageStoryServer and Backup processes
echo "$(timestamp) INFO: Starting Supervisor"
supervisord -c "${VINTAGE_STORY_PATH}/supervisord.conf" &

# Hold us open
wait $!