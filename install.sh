#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="HashCake"
RELEASE_REPO="${HASHCAKE_RELEASE_REPO:-hashultra/hashcake}"
RELEASE_TAG="${HASHCAKE_VERSION:-latest}"
RELEASE_BRANCH="${HASHCAKE_RELEASE_BRANCH:-main}"
RELEASE_PLATFORM="${HASHCAKE_RELEASE_PLATFORM:-linux-amd64}"
RELEASE_SUMS_PATH="SHA256SUMS"
RELEASE_MIRROR_BASE="${HASHCAKE_RELEASE_MIRROR_BASE-https://cdn.jsdmirror.com/gh/${RELEASE_REPO}@${RELEASE_BRANCH}}"
# 国内入口使用的不可变提交号（发行时与 prepare-releases.sh / check-release-readiness.sh 的
# DEFAULT_CDN_REF 保持一致）。分支清单存在缓存窗口，而这个提交的清单不可变，因此它同时也是
# 没有外网时的版本兜底来源。
INSTALLER_ANCHOR_REF="${HASHCAKE_INSTALLER_ANCHOR_REF:-89999b89019e82b17d33cc9e14878610947d2946}"
SERVICE_NAME="${HASHCAKE_SERVICE:-hashcake}"
SERVICE_USER="${HASHCAKE_USER:-hashcake}"
SERVICE_GROUP="${HASHCAKE_GROUP:-${SERVICE_USER}}"
INSTALL_DIR="${HASHCAKE_HOME:-/opt/hashcake}"
CONFIG_DIR="${HASHCAKE_CONFIG_DIR:-${INSTALL_DIR}/config}"
CONFIG_FILE="${HASHCAKE_CONFIG:-${CONFIG_DIR}/hashcake.yaml}"
[ -z "${HASHCAKE_CONFIG:-}" ] || CONFIG_DIR="$(dirname -- "${CONFIG_FILE}")"
LEGACY_CONFIG_FILE="${INSTALL_DIR}/hashcake.yaml"
STATE_DIR="${HASHCAKE_STATE_DIR:-${INSTALL_DIR}/state}"
LOG_DIR="${HASHCAKE_LOG_DIR:-${INSTALL_DIR}/logs}"
BACKUP_DIR="${HASHCAKE_BACKUP_DIR:-${INSTALL_DIR}/backup}"
BIN_PATH="${INSTALL_DIR}/hashcake"
MANIFEST_PATH="${INSTALL_DIR}/hashcake.manifest.json"
INSTALLER_STATE_DIR="${HASHCAKE_INSTALLER_STATE_DIR:-${INSTALL_DIR}/.installer}"
INSTALL_ENV="${INSTALLER_STATE_DIR}/install.env"
LEGACY_INSTALL_ENV="${STATE_DIR}/install.env"
ADMIN_BIND="${HASHCAKE_ADMIN_BIND:-}"
URL_PREFIX="${HASHCAKE_URL_PREFIX:-}"
HTTPS_ACTIVE="${HASHCAKE_HTTPS_ACTIVE:-}"

UPDATE_MANIFEST_URL="${HASHCAKE_UPDATE_MANIFEST_URL:-}"
DOWNLOAD_SHA256="${HASHCAKE_DOWNLOAD_SHA256:-}"
MANIFEST_URL="${HASHCAKE_MANIFEST_URL:-}"
DOWNLOAD_MANIFEST_SHA256="${HASHCAKE_MANIFEST_SHA256:-}"
RUST_LOG_VALUE="${RUST_LOG:-hashcake=info}"
BUILD_FEATURES="${HASHCAKE_FEATURES:-admin-spa}"
START_AFTER_INSTALL="${HASHCAKE_START_AFTER_INSTALL:-1}"
ALLOW_PRERELEASE="${HASHCAKE_ALLOW_PRERELEASE:-0}"
EXPECTED_BINARY_VERSION=""
WEB_PORT_MIN="${HASHCAKE_WEB_PORT_MIN:-10000}"
WEB_PORT_MAX="${HASHCAKE_WEB_PORT_MAX:-60000}"
FIRST_WEB_TOKEN=""
ADMIN_API_BASE=""
# The binary's pending bootstrap window is fixed at ten minutes.  This is
# deliberately a display constant only: the server remains the source of
# truth; installer confirmation only makes its hash survive the final restart.
BOOTSTRAP_TTL_MINUTES=10

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

red=$'\033[31m'
green=$'\033[32m'
yellow=$'\033[33m'
blue=$'\033[34m'
reset=$'\033[0m'

log() { printf '%s\n' "${blue}==>${reset} $*"; }
ok() { printf '%s\n' "${green}完成:${reset} $*"; }
warn() { printf '%s\n' "${yellow}注意:${reset} $*"; }
die() { printf '%s\n' "${red}错误:${reset} $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 运行：sudo bash $0"
}

require_bash_runtime() {
  [ -n "${BASH_VERSION:-}" ] || die "本脚本必须使用 bash 运行"
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash ${BASH_VERSION} 过旧；HashCake 安装器要求 bash >= 4"
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少必要命令：${command_name}"
}

INSTALLER_LOCK_HELD=0
INSTALLER_LOCK_FD=""

acquire_installer_lock() {
  [ "${INSTALLER_LOCK_HELD}" = "0" ] || return 0
  require_command flock
  local lock_dir="/run/lock"
  [ -d "${lock_dir}" ] || lock_dir="/run"
  exec {INSTALLER_LOCK_FD}>"${lock_dir}/${SERVICE_NAME}-installer.lock"
  flock -n "${INSTALLER_LOCK_FD}" \
    || die "另一个 ${APP_NAME} 安装或维护任务正在运行，请稍后重试"
  INSTALLER_LOCK_HELD=1
}

validate_safe_absolute_path() {
  local path="$1" label="$2"
  case "${path}" in
    /*) ;;
    *) die "${label}必须是绝对路径：${path}" ;;
  esac
  case "${path}/" in
    *//*|*/./*|*/../*) die "${label}不能包含重复斜杠、. 或 .. 路径段：${path}" ;;
  esac
  case "${path}" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "${label}不能直接使用系统关键目录：${path}"
      ;;
  esac
  case "${path}" in
    *[%\"\'\\]*) die "${label}包含 systemd unit 不允许的字符：${path}" ;;
  esac
}

validate_runtime_inputs() {
  case "${SERVICE_NAME}" in
    ''|*[!A-Za-z0-9_.-]*|-*|.*|*.service) die "systemd 服务名必须是不带 .service 后缀的安全名称：${SERVICE_NAME}" ;;
  esac
  case "${SERVICE_USER}" in
    ''|*[!a-z0-9_-]*|[!a-z_]*|-*) die "服务用户名不安全：${SERVICE_USER}" ;;
  esac
  case "${SERVICE_GROUP}" in
    ''|*[!a-z0-9_-]*|[!a-z_]*|-*) die "服务组名不安全：${SERVICE_GROUP}" ;;
  esac
  printf '%s' "${RELEASE_REPO}" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || die "发布仓库必须是安全的 owner/repo 格式：${RELEASE_REPO}"
  case "${RELEASE_BRANCH}" in
    ''|*[!A-Za-z0-9._/-]*|*..*|/*|*/|*//* ) die "发布分支名称不安全：${RELEASE_BRANCH}" ;;
  esac
  case "${RELEASE_PLATFORM}" in
    ''|*[!A-Za-z0-9._-]*) die "发布平台名称不安全：${RELEASE_PLATFORM}" ;;
  esac
  case "${RELEASE_MIRROR_BASE}" in
    '') ;;
    https://*)
      printf '%s' "${RELEASE_MIRROR_BASE}" | grep -Eq '^https://[A-Za-z0-9:/?&=._%+#~@-]+$' \
        || die "发布镜像地址包含不安全字符"
      ;;
    *) die "HASHCAKE_RELEASE_MIRROR_BASE 必须使用 https://" ;;
  esac
  if [ "${RELEASE_TAG}" != "latest" ]; then
    printf '%s' "${RELEASE_TAG}" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
      || die "版本号必须是 latest 或 SemVer，例如 v1.2.3：${RELEASE_TAG}"
  fi
  case "${START_AFTER_INSTALL}" in
    0|1) ;;
    *) die "HASHCAKE_START_AFTER_INSTALL 只能是 0 或 1：${START_AFTER_INSTALL}" ;;
  esac
  case "${ALLOW_PRERELEASE}" in
    0|1) ;;
    *) die "HASHCAKE_ALLOW_PRERELEASE 只能是 0 或 1：${ALLOW_PRERELEASE}" ;;
  esac
  case "${RUST_LOG_VALUE}" in
    ''|*[!A-Za-z0-9_=,.:/-]*) die "RUST_LOG 包含 systemd Environment 不支持的字符" ;;
  esac
  case "${UPDATE_MANIFEST_URL}" in
    *[[:space:]]*) die "HASHCAKE_UPDATE_MANIFEST_URL 不能包含空白字符" ;;
  esac
  if [ -n "${UPDATE_MANIFEST_URL}" ]; then
    case "${UPDATE_MANIFEST_URL}" in
      https://*) ;;
      *) die "HASHCAKE_UPDATE_MANIFEST_URL 必须使用 https://" ;;
    esac
    printf '%s' "${UPDATE_MANIFEST_URL}" | grep -Eq '^https://[A-Za-z0-9:/?&=._%+#~-]+$' \
      || die "HASHCAKE_UPDATE_MANIFEST_URL 包含不安全字符"
  fi
  if [ -n "${HASHCAKE_DOWNLOAD_URL:-}" ]; then
    case "${HASHCAKE_DOWNLOAD_URL}" in
      https://*) ;;
      *) die "HASHCAKE_DOWNLOAD_URL 必须使用 https://；本地文件请改用 HASHCAKE_BIN_SOURCE" ;;
    esac
    case "${HASHCAKE_DOWNLOAD_URL}" in
      *[[:space:]]*) die "HASHCAKE_DOWNLOAD_URL 不能包含空白字符" ;;
    esac
  fi
  if [ -n "${MANIFEST_URL}" ]; then
    case "${MANIFEST_URL}" in https://*) ;; *) die "HASHCAKE_MANIFEST_URL 必须使用 https://" ;; esac
    case "${MANIFEST_URL}" in *[[:space:]]*) die "HASHCAKE_MANIFEST_URL 不能包含空白字符" ;; esac
  fi
  if [ -n "${DOWNLOAD_SHA256}" ] \
    && { [ "${#DOWNLOAD_SHA256}" -ne 64 ] || [[ "${DOWNLOAD_SHA256}" == *[!0-9A-Fa-f]* ]]; }; then
    die "HASHCAKE_DOWNLOAD_SHA256 必须是 64 位十六进制 SHA-256"
  fi
  if [ -n "${DOWNLOAD_MANIFEST_SHA256}" ] \
    && { [ "${#DOWNLOAD_MANIFEST_SHA256}" -ne 64 ] || [[ "${DOWNLOAD_MANIFEST_SHA256}" == *[!0-9A-Fa-f]* ]]; }; then
    die "HASHCAKE_MANIFEST_SHA256 必须是 64 位十六进制 SHA-256"
  fi

  validate_safe_absolute_path "${INSTALL_DIR}" "安装目录"
  validate_safe_absolute_path "${CONFIG_DIR}" "配置目录"
  validate_safe_absolute_path "${CONFIG_FILE}" "配置文件"
  validate_safe_absolute_path "${STATE_DIR}" "状态目录"
  validate_safe_absolute_path "${LOG_DIR}" "日志目录"
  validate_safe_absolute_path "${BACKUP_DIR}" "备份目录"
  validate_safe_absolute_path "${INSTALLER_STATE_DIR}" "安装元数据目录"
  validate_safe_absolute_path "${MANIFEST_PATH}" "HashCake manifest 路径"
}

preflight_install_or_update() {
  require_bash_runtime
  need_root
  [ "$(uname -s)" = "Linux" ] || die "一键安装器只支持 Linux，当前系统是 $(uname -s)"
  reject_space_path
  validate_runtime_inputs
  local command_name
  for command_name in awk chmod chown cp dirname getent grep groupadd install mktemp mv od pgrep python3 rm runuser sed sleep sort stat systemctl tail tr useradd wc; do
    require_command "${command_name}"
  done
  if [ -z "${HASHCAKE_BIN_SOURCE:-}" ]; then
    require_command curl
    if ! command_exists sha256sum && ! command_exists shasum; then
      die "缺少 sha256sum 或 shasum，无法校验下载文件"
    fi
  fi
  has_systemd || die "当前系统没有可用 systemd，无法安全安装 HashCake 服务"
  require_hardened_systemd
  acquire_installer_lock
}

reject_space_path() {
  case "${INSTALL_DIR}${CONFIG_DIR}${CONFIG_FILE}${STATE_DIR}${LOG_DIR}${BACKUP_DIR}${INSTALLER_STATE_DIR}" in
    *[[:space:]]*) die "安装路径不能包含空格：${INSTALL_DIR}" ;;
  esac
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

require_hardened_systemd() {
  local version
  version="$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  case "${version}" in
    ''|*[!0-9]*) die "无法识别 systemd 版本，不能确认 ProtectProc 安全能力" ;;
  esac
  [ "${version}" -ge 247 ] || die "systemd ${version} 过旧；HashCake 安全服务要求 systemd >= 247"
}

ensure_service_user() {
  need_root
  if ! getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${SERVICE_GROUP}"
  fi
  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${SERVICE_GROUP}" --home-dir "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}"
  fi
}

run_as_service_user() {
  local current_uid service_uid
  current_uid="$(id -u)"
  service_uid="$(id -u "${SERVICE_USER}" 2>/dev/null)" \
    || die "服务用户不存在：${SERVICE_USER}"
  if [ "${current_uid}" = "${service_uid}" ]; then
    "$@"
    return
  fi
  [ "${current_uid}" = "0" ] || die "该操作需要 root 或 ${SERVICE_USER} 用户权限"
  command -v runuser >/dev/null 2>&1 || die "缺少 runuser，无法以 ${SERVICE_USER} 身份安全写入运行状态"
  runuser -u "${SERVICE_USER}" -- "$@"
}

run_hashcake_as_service_user() {
  run_as_service_user env HASHCAKE_ENVELOPE_EXEC_DIR="${STATE_DIR}" "$@"
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

random_segment() {
  local prefix="$1"
  local body
  if command -v openssl >/dev/null 2>&1; then
    body="$(openssl rand -hex 4)"
  else
    body="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  printf '%s-%s' "${prefix}" "${body}"
}

normalize_url_prefix() {
  local raw="$1"
  raw="${raw#/}"
  raw="${raw%/}"
  [ -n "${raw}" ] || die "安全访问路径不能为空"
  case "${raw}" in
    *[!a-z0-9-]*|*/*|*.*|*_*) die "安全访问路径只能包含小写字母、数字和连字符：${raw}" ;;
    -*|*-) die "安全访问路径不能以连字符开头或结尾：${raw}" ;;
  esac
  if [ "${#raw}" -lt 2 ] || [ "${#raw}" -gt 32 ]; then
    die "安全访问路径长度必须是 2-32 位：${raw}"
  fi
  case "${raw}" in
    api|assets|admin|static|openapi.json|favicon.svg|index.html) die "安全访问路径不能使用保留名称：${raw}" ;;
  esac
  printf '%s' "${raw}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

ipv6_stack_available() {
  [ "$(uname -s)" != "Linux" ] || [ -s /proc/net/if_inet6 ]
}

trim_whitespace() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

count_csv_items() {
  printf '%s\n' "$1" \
    | tr ',' '\n' \
    | awk 'NF { count += 1 } END { print count + 0 }'
}

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
  elif command_exists lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" && return 0
  elif command_exists python3; then
    python3 - "${port}" <<'PY'
import errno
import socket
import sys

port = int(sys.argv[1])
for family, address in (
    (socket.AF_INET, ("0.0.0.0", port)),
    (socket.AF_INET6, ("::", port)),
):
    try:
        sock = socket.socket(family, socket.SOCK_STREAM)
    except OSError:
        continue
    try:
        sock.bind(address)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            raise SystemExit(0)
    finally:
        sock.close()
raise SystemExit(1)
PY
    return $?
  fi
  return 1
}

random_port() {
  local min="${WEB_PORT_MIN}" max="${WEB_PORT_MAX}" span port attempt rand
  case "${min}:${max}" in
    *[!0-9:]*) die "端口范围必须是数字：${min}-${max}" ;;
  esac
  if [ "${min}" -lt 1 ] || [ "${max}" -gt 65535 ] || [ "${min}" -gt "${max}" ]; then
    die "端口范围无效：${min}-${max}"
  fi
  span=$((max - min + 1))
  for ((attempt = 0; attempt < 200; attempt += 1)); do
    if command_exists od; then
      rand="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    else
      rand="${RANDOM}${RANDOM}"
    fi
    port=$((min + rand % span))
    if ! port_in_use "${port}"; then
      printf '%s' "${port}"
      return 0
    fi
  done
  die "无法在 ${min}-${max} 范围内找到空闲端口"
}

validate_port_value() {
  local port="$1"
  case "${port}" in
    ''|*[!0-9]*) die "端口必须是数字：${port}" ;;
  esac
  if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    die "端口必须在 1-65535 范围内：${port}"
  fi
}

validate_admin_bind_for_install() {
  local port
  validate_saved_admin_bind "${ADMIN_BIND}"
  port="$(bind_port "${ADMIN_BIND}")"
  validate_port_value "${port}"
  if port_in_use "${port}"; then
    die "Web 后台端口 ${port} 已被占用，请更换端口后再安装"
  fi
}

bind_port() {
  local bind="$1"
  printf '%s' "${bind##*:}"
}

host_from_bind() {
  local bind="$1"
  printf '%s' "${bind%:*}"
}

ensure_installer_state_dir() {
  need_root
  if [ -e "${INSTALLER_STATE_DIR}" ] || [ -L "${INSTALLER_STATE_DIR}" ]; then
    [ ! -L "${INSTALLER_STATE_DIR}" ] || die "安装元数据目录不能是符号链接：${INSTALLER_STATE_DIR}"
    [ -d "${INSTALLER_STATE_DIR}" ] || die "安装元数据路径不是目录：${INSTALLER_STATE_DIR}"
    [ "$(stat -c '%u' -- "${INSTALLER_STATE_DIR}")" = "0" ] \
      || die "安装元数据目录必须属于 root：${INSTALLER_STATE_DIR}"
  else
    install -d -m 0700 -o root -g root "${INSTALLER_STATE_DIR}"
  fi
  chmod 700 "${INSTALLER_STATE_DIR}"
  chown root:root "${INSTALLER_STATE_DIR}"
}

validate_root_metadata_file() {
  local path="$1" mode
  [ ! -L "${path}" ] || die "安装元数据文件不能是符号链接：${path}"
  [ -f "${path}" ] || die "安装元数据不是普通文件：${path}"
  [ "$(stat -c '%u' -- "${path}")" = "0" ] || die "安装元数据必须属于 root：${path}"
  mode="$(stat -c '%a' -- "${path}")"
  [ "${mode}" = "600" ] || die "安装元数据权限必须是 600，当前为 ${mode}：${path}"
}

decode_install_env_value() {
  local value="$1"
  case "${value}" in
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    *\'*|*\"*) die "安装元数据包含不允许的引号" ;;
  esac
  case "${value}" in
    *$'\r'*|*$'\n'*) die "安装元数据包含换行符" ;;
  esac
  printf '%s' "${value}"
}

validate_saved_admin_bind() {
  local value="$1" host port
  [ -n "${value}" ] || return 0
  case "${value}" in
    \[*\]:[0-9]*)
      host="${value%%]:*}"
      host="${host#\[}"
      ;;
    *:* )
      host="${value%:*}"
      case "${host}" in
        *:*) die "IPv6 监听地址必须使用 [地址]:端口 格式：${value}" ;;
      esac
      ;;
    *) die "管理后台监听地址必须使用 IP:端口 格式：${value}" ;;
  esac
  port="$(bind_port "${value}")"
  validate_port_value "${port}"
  [ -n "${host}" ] || die "安装元数据中的管理后台监听主机为空"
  python3 - "${host}" <<'PY' || die "管理后台监听主机必须是 IPv4 或 IPv6 地址：${value}"
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
  case "${host}" in
    *:*) ipv6_stack_available || die "系统未启用 IPv6，不能监听 ${value}" ;;
  esac
}

validate_saved_https() {
  local value="$1"
  [ -z "${value}" ] && return 0
  case "${value}" in
    true|false|1|0|yes|no|on|off) ;;
    *) die "安装元数据中的 HTTPS 状态无效：${value}" ;;
  esac
}

parse_install_env() {
  local path="$1" line key value
  SAVED_ADMIN_BIND=""
  SAVED_URL_PREFIX=""
  SAVED_HTTPS_ACTIVE=""
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) die "安装元数据包含无效行：${path}" ;;
    esac
    key="${line%%=*}"
    value="$(decode_install_env_value "${line#*=}")"
    case "${key}" in
      SAVED_ADMIN_BIND) SAVED_ADMIN_BIND="${value}" ;;
      SAVED_URL_PREFIX) SAVED_URL_PREFIX="${value}" ;;
      SAVED_HTTPS_ACTIVE) SAVED_HTTPS_ACTIVE="${value}" ;;
      *) die "安装元数据包含未知字段 ${key}：${path}" ;;
    esac
  done < "${path}"
  validate_saved_admin_bind "${SAVED_ADMIN_BIND}"
  [ -z "${SAVED_URL_PREFIX}" ] || SAVED_URL_PREFIX="$(normalize_url_prefix "${SAVED_URL_PREFIX}")"
  validate_saved_https "${SAVED_HTTPS_ACTIVE}"
}

load_existing_web_settings() {
  local exec_line="" security_values=()
  if [ -e "${SERVICE_FILE}" ] || [ -L "${SERVICE_FILE}" ]; then
    [ ! -L "${SERVICE_FILE}" ] || die "systemd 服务文件不能是符号链接：${SERVICE_FILE}"
    [ -f "${SERVICE_FILE}" ] || die "systemd 服务路径不是普通文件：${SERVICE_FILE}"
    [ "$(stat -c '%u' -- "${SERVICE_FILE}")" = "0" ] || die "systemd 服务文件必须属于 root：${SERVICE_FILE}"
    if [ $((8#$(stat -c '%a' -- "${SERVICE_FILE}") & 8#022)) -ne 0 ]; then
      die "systemd 服务文件不能被 group/other 写入：${SERVICE_FILE}"
    fi
    exec_line="$(sed -n 's/^ExecStart=//p' "${SERVICE_FILE}" | tail -n 1)"
    SAVED_ADMIN_BIND="$(printf '%s\n' "${exec_line}" | sed -n 's/.*--admin-bind \([^ ]*\).*/\1/p')"
    validate_saved_admin_bind "${SAVED_ADMIN_BIND}"
  fi

  if [ -s "${STATE_DIR}/admin.json" ] && command_exists python3; then
    mapfile -t security_values < <(python3 - "${STATE_DIR}/admin.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if os.path.islink(path) or not os.path.isfile(path):
    raise SystemExit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(0)
security = data.get("security")
if not isinstance(security, dict):
    raise SystemExit(0)
prefix = security.get("url_prefix")
https_active = security.get("https_active")
print(prefix if isinstance(prefix, str) else "")
print("true" if https_active is True else "false" if https_active is False else "")
PY
)
    [ -z "${security_values[0]:-}" ] || SAVED_URL_PREFIX="$(normalize_url_prefix "${security_values[0]}")"
    SAVED_HTTPS_ACTIVE="${security_values[1]:-}"
    validate_saved_https "${SAVED_HTTPS_ACTIVE}"
  fi

  if [ -e "${LEGACY_INSTALL_ENV}" ] || [ -L "${LEGACY_INSTALL_ENV}" ]; then
    warn "检测到旧版 ${LEGACY_INSTALL_ENV}；该文件由服务账户控制，出于安全原因不会执行或信任，更新后将迁移到 root 专属目录"
  fi
}

# The daemon's Web UI persists a port override under security.admin_port in
# admin.json; it wins over the port recorded in install.env / the systemd unit
# so an upgrade cannot silently revert the operator's choice. The bind host
# still comes from the supervisor metadata. An explicit HASHCAKE_ADMIN_BIND
# environment variable overrides this because load_install_env() resolves
# ADMIN_BIND from it first.
apply_persisted_admin_port() {
  [ -n "${SAVED_ADMIN_BIND:-}" ] || return 0
  command_exists python3 || return 0
  [ -s "${STATE_DIR}/admin.json" ] || return 0
  local port
  port="$(python3 - "${STATE_DIR}/admin.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if os.path.islink(path) or not os.path.isfile(path):
    raise SystemExit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(0)
security = data.get("security")
if not isinstance(security, dict):
    raise SystemExit(0)
port = security.get("admin_port")
if isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535:
    print(port)
PY
)"
  [ -n "${port}" ] || return 0
  SAVED_ADMIN_BIND="$(host_from_bind "${SAVED_ADMIN_BIND}"):${port}"
}

load_install_env() {
  SAVED_ADMIN_BIND=""
  SAVED_URL_PREFIX=""
  SAVED_HTTPS_ACTIVE=""
  if [ -e "${INSTALL_ENV}" ] || [ -L "${INSTALL_ENV}" ]; then
    validate_root_metadata_file "${INSTALL_ENV}"
    parse_install_env "${INSTALL_ENV}"
  else
    load_existing_web_settings
  fi
  apply_persisted_admin_port
  ADMIN_BIND="${HASHCAKE_ADMIN_BIND:-${ADMIN_BIND:-${SAVED_ADMIN_BIND:-}}}"
  URL_PREFIX="${HASHCAKE_URL_PREFIX:-${URL_PREFIX:-${SAVED_URL_PREFIX:-}}}"
  HTTPS_ACTIVE="${HASHCAKE_HTTPS_ACTIVE:-${HTTPS_ACTIVE:-${SAVED_HTTPS_ACTIVE:-}}}"
}

save_install_env() {
  local tmp
  ensure_installer_state_dir
  validate_saved_admin_bind "${ADMIN_BIND}"
  URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  validate_saved_https "${HTTPS_ACTIVE}"
  if [ -e "${INSTALL_ENV}" ] || [ -L "${INSTALL_ENV}" ]; then
    validate_root_metadata_file "${INSTALL_ENV}"
  fi
  umask 077
  tmp="$(mktemp "${INSTALLER_STATE_DIR}/install.env.tmp.XXXXXX")"
  printf 'SAVED_ADMIN_BIND=%s\nSAVED_URL_PREFIX=%s\nSAVED_HTTPS_ACTIVE=%s\n' \
    "${ADMIN_BIND}" "${URL_PREFIX}" "${HTTPS_ACTIVE}" > "${tmp}"
  chmod 600 "${tmp}"
  chown root:root "${tmp}"
  mv -fT "${tmp}" "${INSTALL_ENV}"
  rm -f -- "${LEGACY_INSTALL_ENV}"
}

configure_web_defaults_for_install() {
  if [ -z "${ADMIN_BIND}" ]; then
    ADMIN_BIND="0.0.0.0:$(random_port)"
  fi
  if [ -z "${URL_PREFIX}" ]; then
    URL_PREFIX="$(random_segment hc)"
  else
    URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  fi
  if [ -z "${HTTPS_ACTIVE}" ]; then
    HTTPS_ACTIVE="true"
  fi
}

configure_web_defaults_for_update() {
  load_install_env
  [ -n "${ADMIN_BIND}" ] || ADMIN_BIND="0.0.0.0:$(random_port)"
  [ -n "${URL_PREFIX}" ] || URL_PREFIX="$(random_segment hc)"
  URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  [ -n "${HTTPS_ACTIVE}" ] || HTTPS_ACTIVE="true"
}

persist_admin_security() {
  command_exists python3 || die "缺少 python3，无法安全写入 ${STATE_DIR}/admin.json"
  local admin_json="${STATE_DIR}/admin.json" admin_port
  admin_port="$(bind_port "${ADMIN_BIND}")"
  run_as_service_user python3 - "${admin_json}" "${URL_PREFIX}" "${HTTPS_ACTIVE}" "${admin_port}" <<'PY'
import json
import os
import stat
import sys
import tempfile

path, prefix, https_active, admin_port = sys.argv[1:5]
data = {}
try:
    current = os.lstat(path)
except FileNotFoundError:
    current = None
if current is not None and (stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode)):
    raise SystemExit(f"unsafe admin state path: {path}")
if current is not None and current.st_size > 0:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
if not isinstance(data, dict):
    data = {}
security = data.get("security")
if not isinstance(security, dict):
    security = {}
security["version"] = int(security.get("version", 2) or 2)
security["url_prefix"] = prefix
security["https_enabled"] = False
security["https_active"] = https_active.lower() in ("1", "true", "yes", "on")
security["admin_port"] = int(admin_port)
security.setdefault("offline_alerts_enabled", True)
security.setdefault("ip_blacklist", [])
security.setdefault("wallet_blacklist", [])
data["security"] = security
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".admin.json.", dir=directory)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

admin_store_state() {
  command_exists python3 || die "缺少 python3，无法检查 ${STATE_DIR}/admin.json"
  local admin_json="${STATE_DIR}/admin.json"
  if [ ! -e "${admin_json}" ] && [ ! -L "${admin_json}" ]; then
    printf 'missing'
    return 0
  fi
  [ ! -L "${admin_json}" ] || die "后台状态文件不能是符号链接：${admin_json}"
  [ -f "${admin_json}" ] || die "后台状态路径不是普通文件：${admin_json}"
  python3 - "${admin_json}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    raw = fh.read()
if not raw.strip():
    data = {}
else:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"malformed admin state {path}: {exc}")
if not isinstance(data, dict):
    raise SystemExit(f"admin state root is not an object: {path}")

tokens = data.get("tokens", [])
accounts = data.get("accounts", [])
if not isinstance(tokens, list):
    raise SystemExit(f"admin state tokens is not an array: {path}")
if not isinstance(accounts, list):
    raise SystemExit(f"admin state accounts is not an array: {path}")
legacy_hash = data.get("active_hash_sha256_hex")
has_legacy_token = isinstance(legacy_hash, str) and bool(legacy_hash.strip())
print("provisioned" if tokens or accounts or has_legacy_token else "uninitialized", end="")
PY
}

is_installed() {
  [ -x "${BIN_PATH}" ] || [ -f "${SERVICE_FILE}" ] || [ -f "${INSTALL_ENV}" ] || [ -f "${LEGACY_INSTALL_ENV}" ]
}

is_complete_install() {
  [ -x "${BIN_PATH}" ] && [ -f "${SERVICE_FILE}" ]
}

running_processes() {
  pgrep -af '(^|/)hashcake( |$)' 2>/dev/null || true
}

check_no_running_conflict() {
  if has_systemd && systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    die "检测到 ${SERVICE_NAME}.service 正在运行；首次安装前请先停止，已安装请使用 update"
  fi
  local running
  running="$(running_processes | grep -v "pgrep -af" || true)"
  [ -z "${running}" ] || die "检测到正在运行的 HashCake 进程，首次安装已停止：
${running}"
}

systemd_unit_exists() {
  local unit="$1"
  systemctl list-unit-files "${unit}" --no-legend 2>/dev/null \
    | awk -v expected="${unit}" '$1 == expected { found = 1 } END { exit found ? 0 : 1 }'
}

firewall_unit_list() {
  printf '%s\n' \
    ufw.service \
    firewalld.service \
    nftables.service \
    iptables.service \
    ip6tables.service \
    netfilter-persistent.service \
    ferm.service \
    shorewall.service \
    shorewall6.service
}

FIREWALL_SNAPSHOT_DIR=""
FIREWALL_ROLLBACK_ARMED=0
FIREWALL_PRESERVED=0
INSTALL_TRANSACTION_ACTIVE=0
INSTALL_TRANSACTION_DIR=""
INSTALL_CANDIDATE_DIR=""
TXN_HAD_BINARY=0
TXN_HAD_MANIFEST=0
TXN_HAD_SERVICE=0
TXN_HAD_INSTALL_ENV=0
TXN_HAD_LEGACY_INSTALL_ENV=0
TXN_HAD_ADMIN_JSON=0
TXN_HAD_CONFIG=0
TXN_SERVICE_WAS_ENABLED=0
TXN_SERVICE_WAS_ACTIVE=0
TXN_BINARY_CHANGED=0
TXN_MANIFEST_CHANGED=0
TXN_SERVICE_CHANGED=0

cleanup_install_candidate() {
  if [ -n "${INSTALL_CANDIDATE_DIR}" ]; then
    rm -rf -- "${INSTALL_CANDIDATE_DIR}"
    INSTALL_CANDIDATE_DIR=""
  fi
}

write_install_transaction_journal() {
  python3 - "${INSTALL_TRANSACTION_DIR}" \
    "${TXN_HAD_BINARY}" "${TXN_HAD_MANIFEST}" "${TXN_HAD_SERVICE}" \
    "${TXN_HAD_INSTALL_ENV}" "${TXN_HAD_LEGACY_INSTALL_ENV}" \
    "${TXN_HAD_ADMIN_JSON}" "${TXN_HAD_CONFIG}" \
    "${TXN_SERVICE_WAS_ENABLED}" "${TXN_SERVICE_WAS_ACTIVE}" <<'PY'
import json
import os
import sys
from pathlib import Path

directory = Path(sys.argv[1])
keys = [
    "had_binary", "had_manifest", "had_service", "had_install_env",
    "had_legacy_install_env", "had_admin_json", "had_config",
    "service_was_enabled", "service_was_active",
]
values = [int(value) for value in sys.argv[2:]]
if any(value not in (0, 1) for value in values):
    raise SystemExit("invalid install transaction flag")
payload = {"schema_version": 1, **dict(zip(keys, values))}
# Backups must reach disk before phase-active makes recovery authoritative.
for child in directory.iterdir():
    if child.is_file() and not child.is_symlink():
        fd = os.open(child, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
tmp = directory / ".journal.tmp"
journal = directory / "journal.json"
with open(tmp, "x", encoding="utf-8") as handle:
    os.chmod(tmp, 0o600)
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, journal)
phase = directory / "phase-active"
fd = os.open(phase, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
os.fsync(fd)
os.close(fd)
dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
os.fsync(dir_fd)
os.close(dir_fd)
parent_fd = os.open(directory.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
os.fsync(parent_fd)
os.close(parent_fd)
PY
}

mark_install_transaction_committed() {
  python3 - "${INSTALL_TRANSACTION_DIR}" \
    "${BIN_PATH}" "${MANIFEST_PATH}" "${SERVICE_FILE}" "${INSTALL_ENV}" \
    "${LEGACY_INSTALL_ENV}" "${STATE_DIR}/admin.json" "${CONFIG_FILE}" <<'PY'
import os
import sys
from pathlib import Path

directory = Path(sys.argv[1])
parents = {directory}
for raw in sys.argv[2:]:
    path = Path(raw)
    parents.add(path.parent)
    if path.exists() and path.is_file() and not path.is_symlink():
        fd = os.open(path, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
for parent in parents:
    if parent.exists():
        fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        os.fsync(fd)
        os.close(fd)
phase = directory / "phase-committed"
fd = os.open(phase, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
os.fsync(fd)
os.close(fd)
dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
os.fsync(dir_fd)
os.close(dir_fd)
PY
}

sync_install_transaction_targets() {
  python3 - "${BIN_PATH}" "${MANIFEST_PATH}" "${SERVICE_FILE}" "${INSTALL_ENV}" \
    "${LEGACY_INSTALL_ENV}" "${STATE_DIR}/admin.json" "${CONFIG_FILE}" <<'PY'
import os
import stat
import sys
from pathlib import Path

parents = set()
for raw in sys.argv[1:]:
    path = Path(raw)
    parents.add(path.parent)
    try:
        info = path.lstat()
    except FileNotFoundError:
        continue
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SystemExit(f"install transaction target is not a safe regular file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if opened.st_dev != info.st_dev or opened.st_ino != info.st_ino:
            raise SystemExit(f"install transaction target changed while syncing: {path}")
        os.fsync(fd)
    finally:
        os.close(fd)

for parent in sorted(parents, key=lambda item: str(item)):
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(parent, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

durably_remove_install_transaction() {
  local txn="$1" parent
  [ -n "${txn}" ] || return 0
  case "${txn}" in
    "${BACKUP_DIR}"/.install-transaction.*) ;;
    *) warn "拒绝清理备份目录外的安装事务：${txn}"; return 1 ;;
  esac
  [ ! -L "${txn}" ] || { warn "拒绝清理符号链接安装事务：${txn}"; return 1; }
  parent="$(dirname -- "${txn}")"
  rm -rf -- "${txn}" || return 1
  python3 - "${parent}" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

restore_install_transaction_systemd_state() {
  local failed=0
  has_systemd || return 0
  systemctl daemon-reload >/dev/null 2>&1 || failed=1
  if [ "${TXN_SERVICE_WAS_ENABLED}" = "1" ]; then
    systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || failed=1
    systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null || failed=1
  else
    systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
      failed=1
    fi
  fi
  if [ "${TXN_SERVICE_WAS_ACTIVE}" = "1" ]; then
    restart_service_checked >/dev/null 2>&1 || failed=1
  elif systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    failed=1
  fi
  [ "${failed}" = "0" ]
}

recover_orphan_install_transactions() {
  local txn marker fields=() failed expected_uid mode owner journal_output active_list
  local -a active_txns=()
  expected_uid="$(id -u)"

  # A single active journal has an unambiguous rollback target. Multiple active
  # journals can exist after repeated kill -9 interruptions on an older
  # installer that did not recover before starting maintenance. Their random
  # mktemp names do not encode nesting order, so applying them in glob order
  # could restore the wrong generation. Detect that state before changing any
  # file and preserve every journal for explicit recovery.
  for txn in "${BACKUP_DIR}"/.install-transaction.*; do
    [ -d "${txn}" ] || continue
    [ ! -L "${txn}" ] || die "安装事务恢复拒绝符号链接：${txn}"
    read -r owner mode < <(python3 - "${txn}" <<'PY'
import os, stat, sys
info = os.lstat(sys.argv[1])
print(info.st_uid, oct(stat.S_IMODE(info.st_mode))[2:])
PY
    )
    [ "${owner}" = "${expected_uid}" ] \
      || die "安装事务目录所有者异常：${txn}"
    [ "${mode}" = "700" ] || die "安装事务目录权限必须为 700：${txn}"
    for marker in phase-active phase-committed; do
      if [ -e "${txn}/${marker}" ] || [ -L "${txn}/${marker}" ]; then
        [ -f "${txn}/${marker}" ] && [ ! -L "${txn}/${marker}" ] \
          || die "安装事务阶段标记必须是普通非符号链接文件：${txn}/${marker}"
      fi
    done
    if [ ! -f "${txn}/phase-committed" ] && [ -f "${txn}/phase-active" ]; then
      active_txns+=("${txn}")
    fi
  done
  if [ "${#active_txns[@]}" -gt 1 ]; then
    printf -v active_list ' %q' "${active_txns[@]}"
    die "检测到多个未提交的活动安装事务，无法安全判断回滚顺序；已完整保留现场：${active_list# }"
  fi

  for txn in "${BACKUP_DIR}"/.install-transaction.*; do
    [ -d "${txn}" ] || continue
    [ ! -L "${txn}" ] || die "安装事务恢复拒绝符号链接：${txn}"
    read -r owner mode < <(python3 - "${txn}" <<'PY'
import os, stat, sys
info = os.lstat(sys.argv[1])
print(info.st_uid, oct(stat.S_IMODE(info.st_mode))[2:])
PY
    )
    [ "${owner}" = "${expected_uid}" ] \
      || die "安装事务目录所有者异常：${txn}"
    [ "${mode}" = "700" ] || die "安装事务目录权限必须为 700：${txn}"
    if [ -f "${txn}/phase-committed" ]; then
      durably_remove_install_transaction "${txn}" \
        || die "无法持久清理已提交安装事务：${txn}"
      continue
    fi
    if [ ! -f "${txn}/phase-active" ]; then
      warn "清理尚未进入文件替换阶段的残留安装事务：${txn}"
      durably_remove_install_transaction "${txn}" \
        || die "无法持久清理未激活安装事务：${txn}"
      continue
    fi
    if [ ! -f "${txn}/journal.json" ] || [ -L "${txn}/journal.json" ]; then
      die "活动安装事务缺少安全 journal：${txn}"
    fi
    if ! journal_output="$(python3 - "${txn}/journal.json" <<'PY'
import json
import sys

expected = [
    "had_binary", "had_manifest", "had_service", "had_install_env",
    "had_legacy_install_env", "had_admin_json", "had_config",
    "service_was_enabled", "service_was_active",
]
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if set(value) != set(["schema_version"] + expected) or value["schema_version"] != 1:
    raise SystemExit("invalid install transaction journal schema")
for key in expected:
    if value[key] not in (0, 1):
        raise SystemExit(f"invalid {key}")
    print(value[key])
PY
    )"; then
      die "无法解析安装事务 journal：${txn}"
    fi
    fields=()
    while IFS= read -r value; do fields+=("${value}"); done <<< "${journal_output}"
    [ "${#fields[@]}" -eq 9 ] || die "安装事务 journal 字段数量错误：${txn}"

    warn "发现上次未提交的安装事务，恢复 binary + manifest + 配置：${txn}"
    INSTALL_TRANSACTION_DIR="${txn}"
    TXN_HAD_BINARY="${fields[0]}"
    TXN_HAD_MANIFEST="${fields[1]}"
    TXN_HAD_SERVICE="${fields[2]}"
    TXN_HAD_INSTALL_ENV="${fields[3]}"
    TXN_HAD_LEGACY_INSTALL_ENV="${fields[4]}"
    TXN_HAD_ADMIN_JSON="${fields[5]}"
    TXN_HAD_CONFIG="${fields[6]}"
    TXN_SERVICE_WAS_ENABLED="${fields[7]}"
    TXN_SERVICE_WAS_ACTIVE="${fields[8]}"
    failed=0
    if has_systemd; then
      systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    fi
    restore_transaction_file "${BIN_PATH}" binary "${TXN_HAD_BINARY}" || failed=1
    restore_transaction_file "${MANIFEST_PATH}" manifest "${TXN_HAD_MANIFEST}" || failed=1
    restore_transaction_file "${SERVICE_FILE}" service "${TXN_HAD_SERVICE}" || failed=1
    restore_transaction_file "${INSTALL_ENV}" install-env "${TXN_HAD_INSTALL_ENV}" || failed=1
    restore_transaction_file "${LEGACY_INSTALL_ENV}" legacy-install-env "${TXN_HAD_LEGACY_INSTALL_ENV}" || failed=1
    restore_transaction_file "${STATE_DIR}/admin.json" admin-json "${TXN_HAD_ADMIN_JSON}" || failed=1
    restore_transaction_file "${CONFIG_FILE}" config "${TXN_HAD_CONFIG}" || failed=1
    sync_install_transaction_targets || failed=1
    restore_install_transaction_systemd_state || failed=1
    [ "${failed}" = "0" ] || die "未提交安装事务自动恢复不完整：${txn}"
    cleanup_install_transaction \
      || die "恢复完成但无法持久清理安装事务：${txn}"
    ok "已恢复上次中断前的完整发布文件与配置"
  done
}

prepare_install_transaction_environment() {
  ensure_dirs
  recover_orphan_install_transactions
}

backup_transaction_file() {
  local path="$1" name="$2" flag_name="$3"
  if [ -e "${path}" ] || [ -L "${path}" ]; then
    [ ! -L "${path}" ] || die "事务备份拒绝符号链接：${path}"
    [ -f "${path}" ] || die "事务备份目标不是普通文件：${path}"
    cp -p -- "${path}" "${INSTALL_TRANSACTION_DIR}/${name}"
    printf -v "${flag_name}" '%s' 1
  fi
}

restore_transaction_file() {
  local path="$1" name="$2" existed="$3" restore_tmp
  if [ "${existed}" = "1" ]; then
    restore_tmp="$(mktemp "$(dirname -- "${path}")/.hashcake-restore.XXXXXX")" \
      || { warn "无法为 ${path} 创建恢复临时文件"; return 1; }
    if ! cp -p -- "${INSTALL_TRANSACTION_DIR}/${name}" "${restore_tmp}"; then
      rm -f -- "${restore_tmp}"
      warn "无法准备 ${path} 的恢复文件"
      return 1
    fi
    if ! mv -f -- "${restore_tmp}" "${path}"; then
      rm -f -- "${restore_tmp}"
      warn "无法原子恢复 ${path}"
      return 1
    fi
  else
    rm -f -- "${path}" || return 1
  fi
}

begin_install_transaction() {
  [ "${INSTALL_TRANSACTION_ACTIVE}" = "0" ] || die "安装事务已经启动"
  TXN_HAD_BINARY=0
  TXN_HAD_MANIFEST=0
  TXN_HAD_SERVICE=0
  TXN_HAD_INSTALL_ENV=0
  TXN_HAD_LEGACY_INSTALL_ENV=0
  TXN_HAD_ADMIN_JSON=0
  TXN_HAD_CONFIG=0
  TXN_SERVICE_WAS_ENABLED=0
  TXN_SERVICE_WAS_ACTIVE=0
  TXN_BINARY_CHANGED=0
  TXN_MANIFEST_CHANGED=0
  TXN_SERVICE_CHANGED=0
  INSTALL_TRANSACTION_DIR="$(mktemp -d "${BACKUP_DIR}/.install-transaction.XXXXXX")"
  chmod 700 "${INSTALL_TRANSACTION_DIR}"

  backup_transaction_file "${BIN_PATH}" binary TXN_HAD_BINARY
  backup_transaction_file "${MANIFEST_PATH}" manifest TXN_HAD_MANIFEST
  backup_transaction_file "${SERVICE_FILE}" service TXN_HAD_SERVICE
  backup_transaction_file "${INSTALL_ENV}" install-env TXN_HAD_INSTALL_ENV
  backup_transaction_file "${LEGACY_INSTALL_ENV}" legacy-install-env TXN_HAD_LEGACY_INSTALL_ENV
  backup_transaction_file "${STATE_DIR}/admin.json" admin-json TXN_HAD_ADMIN_JSON
  backup_transaction_file "${CONFIG_FILE}" config TXN_HAD_CONFIG

  if has_systemd && systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    TXN_SERVICE_WAS_ENABLED=1
  fi
  if has_systemd && systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    TXN_SERVICE_WAS_ACTIVE=1
  fi
  INSTALL_TRANSACTION_ACTIVE=1
  write_install_transaction_journal \
    || { INSTALL_TRANSACTION_ACTIVE=0; cleanup_install_transaction; die "无法持久化安装事务 journal"; }
  trap 'install_exit_guard "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

cleanup_install_transaction() {
  if [ -n "${INSTALL_TRANSACTION_DIR}" ]; then
    durably_remove_install_transaction "${INSTALL_TRANSACTION_DIR}" || return 1
    INSTALL_TRANSACTION_DIR=""
  fi
}

rollback_install_transaction() {
  local failed=0
  [ "${INSTALL_TRANSACTION_ACTIVE}" = "1" ] || return 0
  warn "安装或更新未完成，正在恢复执行前状态"
  cleanup_install_candidate

  if [ "${FIREWALL_ROLLBACK_ARMED}" = "1" ]; then
    restore_firewall_state || failed=1
    FIREWALL_ROLLBACK_ARMED=0
  fi
  if has_systemd && { [ "${TXN_BINARY_CHANGED}" = "1" ] || [ "${TXN_MANIFEST_CHANGED}" = "1" ] || [ "${TXN_SERVICE_CHANGED}" = "1" ]; }; then
    systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  fi

  if [ "${TXN_BINARY_CHANGED}" = "1" ]; then
    restore_transaction_file "${BIN_PATH}" binary "${TXN_HAD_BINARY}" || failed=1
  fi
  if [ "${TXN_MANIFEST_CHANGED}" = "1" ]; then
    restore_transaction_file "${MANIFEST_PATH}" manifest "${TXN_HAD_MANIFEST}" || failed=1
  fi
  if [ "${TXN_SERVICE_CHANGED}" = "1" ]; then
    restore_transaction_file "${SERVICE_FILE}" service "${TXN_HAD_SERVICE}" || failed=1
  fi
  restore_transaction_file "${INSTALL_ENV}" install-env "${TXN_HAD_INSTALL_ENV}" || failed=1
  restore_transaction_file "${LEGACY_INSTALL_ENV}" legacy-install-env "${TXN_HAD_LEGACY_INSTALL_ENV}" || failed=1
  restore_transaction_file "${STATE_DIR}/admin.json" admin-json "${TXN_HAD_ADMIN_JSON}" || failed=1
  restore_transaction_file "${CONFIG_FILE}" config "${TXN_HAD_CONFIG}" || failed=1
  sync_install_transaction_targets || failed=1

  restore_install_transaction_systemd_state || failed=1

  cleanup_firewall_snapshot
  if [ "${failed}" = "0" ]; then
    cleanup_install_transaction || failed=1
  fi
  INSTALL_TRANSACTION_ACTIVE=0
  if [ "${failed}" = "0" ]; then
    ok "已恢复执行前的二进制、manifest、服务和安装配置"
  else
    warn "自动恢复不完整，请检查 ${BIN_PATH} 和 ${SERVICE_FILE}；未提交事务已保留：${INSTALL_TRANSACTION_DIR}"
  fi
}

commit_install_transaction() {
  [ "${INSTALL_TRANSACTION_ACTIVE}" = "1" ] || die "没有可提交的安装事务"
  if [ "${FIREWALL_ROLLBACK_ARMED}" = "1" ]; then
    commit_firewall_change
  fi
  mark_install_transaction_committed
  INSTALL_TRANSACTION_ACTIVE=0
  cleanup_install_candidate
  cleanup_install_transaction
  trap - EXIT INT TERM
}

install_exit_guard() {
  local status="$1"
  trap - EXIT INT TERM
  rollback_install_transaction || true
  [ "${status}" -ne 0 ] || status=1
  exit "${status}"
}

capture_firewall_state() {
  local unit enabled active
  [ -z "${FIREWALL_SNAPSHOT_DIR}" ] || die "防火墙事务已经启动"
  FIREWALL_SNAPSHOT_DIR="$(mktemp -d /run/hashcake-firewall.XXXXXX)"
  chmod 700 "${FIREWALL_SNAPSHOT_DIR}"
  : > "${FIREWALL_SNAPSHOT_DIR}/units.tsv"
  chmod 600 "${FIREWALL_SNAPSHOT_DIR}/units.tsv"

  if command_exists ufw && ufw status 2>/dev/null | grep -Eiq '^Status:[[:space:]]*active'; then
    : > "${FIREWALL_SNAPSHOT_DIR}/ufw-active"
  fi
  if command_exists iptables-save; then
    iptables-save > "${FIREWALL_SNAPSHOT_DIR}/iptables.before" \
      || die "无法备份当前 iptables 规则，防火墙尚未修改"
    chmod 600 "${FIREWALL_SNAPSHOT_DIR}/iptables.before"
  fi
  if ipv6_stack_available && command_exists ip6tables-save; then
    ip6tables-save > "${FIREWALL_SNAPSHOT_DIR}/ip6tables.before" \
      || die "无法备份当前 ip6tables 规则，防火墙尚未修改"
    chmod 600 "${FIREWALL_SNAPSHOT_DIR}/ip6tables.before"
  fi

  while IFS= read -r unit; do
    systemd_unit_exists "${unit}" || continue
    enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "${unit}" "${enabled:-unknown}" "${active:-unknown}" \
      >> "${FIREWALL_SNAPSHOT_DIR}/units.tsv"
  done < <(firewall_unit_list)
}

restore_firewall_unit_enablement() {
  local unit="$1" enabled="$2"
  case "${enabled}" in
    enabled|linked|alias) systemctl enable "${unit}" >/dev/null 2>&1 || return 1 ;;
    enabled-runtime|linked-runtime) systemctl enable --runtime "${unit}" >/dev/null 2>&1 || return 1 ;;
    disabled) systemctl disable "${unit}" >/dev/null 2>&1 || return 1 ;;
    masked) systemctl mask "${unit}" >/dev/null 2>&1 || return 1 ;;
    masked-runtime) systemctl mask --runtime "${unit}" >/dev/null 2>&1 || return 1 ;;
    static|indirect|generated|transient|not-found|unknown|'') ;;
    *) warn "无法精确恢复 ${unit} 的启用状态 ${enabled}，将只恢复运行状态" ;;
  esac
}

restore_firewall_state() {
  local unit enabled active failed=0
  [ -n "${FIREWALL_SNAPSHOT_DIR}" ] || return 0
  warn "HashCake 未成功启动，正在恢复安装前的防火墙状态"

  if command_exists ufw; then
    if [ -f "${FIREWALL_SNAPSHOT_DIR}/ufw-active" ]; then
      ufw --force enable >/dev/null 2>&1 || failed=1
    else
      ufw --force disable >/dev/null 2>&1 || failed=1
    fi
  fi

  while IFS=$'\t' read -r unit enabled active; do
    [ -n "${unit}" ] || continue
    restore_firewall_unit_enablement "${unit}" "${enabled}" || failed=1
    case "${active}" in
      active|activating|reloading) systemctl start "${unit}" >/dev/null 2>&1 || failed=1 ;;
      inactive|failed|deactivating) systemctl stop "${unit}" >/dev/null 2>&1 || failed=1 ;;
    esac
  done < "${FIREWALL_SNAPSHOT_DIR}/units.tsv"

  if [ -f "${FIREWALL_SNAPSHOT_DIR}/iptables.before" ]; then
    if command_exists iptables-restore; then
      iptables-restore < "${FIREWALL_SNAPSHOT_DIR}/iptables.before" || failed=1
    else
      failed=1
    fi
  fi
  if [ -f "${FIREWALL_SNAPSHOT_DIR}/ip6tables.before" ]; then
    if command_exists ip6tables-restore; then
      ip6tables-restore < "${FIREWALL_SNAPSHOT_DIR}/ip6tables.before" || failed=1
    else
      failed=1
    fi
  fi

  if [ "${failed}" = "0" ]; then
    ok "已恢复安装前的防火墙状态"
  else
    warn "防火墙自动恢复不完整，请立即检查 ufw/firewalld/nftables 状态"
  fi
}

cleanup_firewall_snapshot() {
  if [ -n "${FIREWALL_SNAPSHOT_DIR}" ]; then
    rm -rf -- "${FIREWALL_SNAPSHOT_DIR}"
    FIREWALL_SNAPSHOT_DIR=""
  fi
}

firewall_exit_guard() {
  local status="$1"
  trap - EXIT
  if [ "${FIREWALL_ROLLBACK_ARMED}" = "1" ]; then
    restore_firewall_state || true
  fi
  cleanup_firewall_snapshot
  exit "${status}"
}

arm_firewall_rollback() {
  capture_firewall_state
  FIREWALL_ROLLBACK_ARMED=1
  if [ "${INSTALL_TRANSACTION_ACTIVE}" != "1" ]; then
    trap 'firewall_exit_guard "$?"' EXIT
  fi
}

commit_firewall_change() {
  FIREWALL_ROLLBACK_ARMED=0
  if [ "${INSTALL_TRANSACTION_ACTIVE}" != "1" ]; then
    trap - EXIT
  fi
  cleanup_firewall_snapshot
}

disable_firewall_unit() {
  local unit="$1"
  systemd_unit_exists "${unit}" || return 1
  systemctl disable --now "${unit}" >/dev/null 2>&1 \
    || die "无法关闭并禁用 ${unit}；为避免后续代理端口被拦截，安装已停止"
  if systemctl is-active --quiet "${unit}"; then
    die "${unit} 关闭后仍处于 active 状态；为避免后续代理端口被拦截，安装已停止"
  fi
  if systemctl is-enabled --quiet "${unit}"; then
    die "${unit} 关闭后仍处于 enabled 状态；为避免重启后防火墙恢复，安装已停止"
  fi
  ok "已关闭并禁用 ${unit}"
}

nft_input_filter_is_open() {
  command_exists nft || return 0
  command_exists python3 || die "缺少 python3，无法确认 nftables INPUT 是否已完全放行"
  local nft_json="${FIREWALL_SNAPSHOT_DIR}/nft-after.json"
  nft -j list ruleset > "${nft_json}" 2>/dev/null \
    || die "无法读取 nftables 规则，不能确认整机防火墙已关闭"
  python3 - "${nft_json}" <<'PY'
import collections
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    objects = json.load(fh).get("nftables", [])

chains = {}
rules = collections.defaultdict(list)
for item in objects:
    chain = item.get("chain")
    if isinstance(chain, dict):
        key = (chain.get("family"), chain.get("table"), chain.get("name"))
        chains[key] = chain
    rule = item.get("rule")
    if isinstance(rule, dict):
        key = (rule.get("family"), rule.get("table"), rule.get("chain"))
        rules[key].append(rule.get("expr") or [])

def chain_blocks(key, visiting):
    if key in visiting:
        return False
    visiting = visiting | {key}
    for expr in rules.get(key, []):
        for statement in expr:
            if not isinstance(statement, dict):
                continue
            if "drop" in statement or "reject" in statement:
                return True
            xt = statement.get("xt")
            if isinstance(xt, dict) and str(xt.get("name", "")).upper() in {"DROP", "REJECT"}:
                return True
            target = None
            jump = statement.get("jump")
            goto = statement.get("goto")
            if isinstance(jump, dict):
                target = jump.get("target")
            elif isinstance(goto, dict):
                target = goto.get("target")
            if isinstance(target, str):
                child = (key[0], key[1], target)
                if child in chains and chain_blocks(child, visiting):
                    return True
    return False

for key, chain in chains.items():
    if chain.get("hook") != "input" or chain.get("type") != "filter":
        continue
    if chain.get("policy", "accept") != "accept" or chain_blocks(key, set()):
        raise SystemExit(1)
PY
}

iptables_input_filter_is_open() {
  local saver="$1"
  command_exists "${saver}" || return 0
  command_exists python3 || die "缺少 python3，无法确认 ${saver} INPUT 是否已完全放行"
  local rules_file="${FIREWALL_SNAPSHOT_DIR}/${saver}.after"
  "${saver}" > "${rules_file}" 2>/dev/null \
    || die "无法读取 ${saver} 规则，不能确认整机防火墙已关闭"
  python3 - "${rules_file}" <<'PY'
import shlex
import sys

policies = {}
jumps = {}
in_filter = False
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.strip()
        if line.startswith("*"):
            in_filter = line == "*filter"
            continue
        if not in_filter or not line or line == "COMMIT":
            continue
        if line.startswith(":"):
            parts = line[1:].split()
            if len(parts) >= 2:
                policies[parts[0]] = parts[1]
            continue
        try:
            parts = shlex.split(line)
        except ValueError:
            raise SystemExit(2)
        if len(parts) < 2 or parts[0] != "-A":
            continue
        chain = parts[1]
        target = None
        for flag in ("-j", "--jump", "-g", "--goto"):
            if flag in parts:
                index = parts.index(flag)
                if index + 1 < len(parts):
                    target = parts[index + 1]
                    break
        if target:
            jumps.setdefault(chain, []).append(target)

def blocks(chain, visiting):
    if chain in visiting:
        return False
    visiting = visiting | {chain}
    for target in jumps.get(chain, []):
        upper = target.upper()
        if upper in {"DROP", "REJECT"}:
            return True
        if target in policies and blocks(target, visiting):
            return True
    return False

if policies.get("INPUT", "ACCEPT") != "ACCEPT" or blocks("INPUT", set()):
    raise SystemExit(1)
PY
}

verify_firewall_disabled() {
  local unit
  if command_exists ufw && ufw status 2>/dev/null | grep -Eiq '^Status:[[:space:]]*active'; then
    die "ufw 关闭后仍显示 active；不能保证后续代理端口自动开放"
  fi
  while IFS= read -r unit; do
    systemd_unit_exists "${unit}" || continue
    systemctl is-active --quiet "${unit}" \
      && die "${unit} 关闭后仍处于 active 状态；不能保证后续代理端口自动开放"
    systemctl is-enabled --quiet "${unit}" \
      && die "${unit} 关闭后仍处于 enabled 状态；重启后可能重新拦截代理端口"
  done < <(firewall_unit_list)
  nft_input_filter_is_open \
    || die "仍检测到 nftables INPUT 的 drop/reject 规则；安装器不会谎报整机防火墙已关闭"
  iptables_input_filter_is_open iptables-save \
    || die "仍检测到 iptables INPUT 的 drop/reject 规则；安装器不会谎报整机防火墙已关闭"
  if ipv6_stack_available; then
    iptables_input_filter_is_open ip6tables-save \
      || die "仍检测到 ip6tables INPUT 的 drop/reject 规则；安装器不会谎报整机防火墙已关闭"
  fi
}

open_iptables_input_filter() {
  local tool="$1"
  command_exists "${tool}" || return 1
  "${tool}" -w 5 -P INPUT ACCEPT >/dev/null 2>&1 \
    || die "无法把 ${tool} INPUT 默认策略改为 ACCEPT；安装已停止"
  "${tool}" -w 5 -F INPUT >/dev/null 2>&1 \
    || die "无法清空 ${tool} INPUT 规则；安装已停止"
  ok "已放行 ${tool} INPUT 链"
}

disable_firewall_now() {
  need_root
  has_systemd || die "当前系统没有可用 systemd，无法确认整机防火墙已关闭"

  local detected=0
  if command_exists ufw; then
    detected=1
    ufw --force disable >/dev/null 2>&1 \
      || die "无法关闭 ufw；为避免后续代理端口被拦截，安装已停止"
    if ufw status 2>/dev/null | grep -Eiq '^Status:[[:space:]]*active'; then
      die "ufw 关闭后仍显示 active；为避免后续代理端口被拦截，安装已停止"
    fi
    if systemd_unit_exists ufw.service; then
      disable_firewall_unit ufw.service
    else
      ok "已关闭 ufw"
    fi
  fi

  local unit
  while IFS= read -r unit; do
    [ "${unit}" = "ufw.service" ] && continue
    if systemd_unit_exists "${unit}"; then
      detected=1
      disable_firewall_unit "${unit}"
    fi
  done < <(firewall_unit_list)

  if command_exists iptables; then
    detected=1
    open_iptables_input_filter iptables
  fi
  if ipv6_stack_available && command_exists ip6tables; then
    detected=1
    open_iptables_input_filter ip6tables
  fi

  if [ "${detected}" = "0" ]; then
    ok "未检测到常见主机防火墙服务，将继续核验 INPUT 是否完全放行"
  fi
  verify_firewall_disabled
  warn "整机防火墙已按 HashCake 运行要求关闭；云厂商安全组和上游网络 ACL 不受安装器控制。"
}

configure_install_firewall() {
  FIREWALL_PRESERVED=0
  if command_exists nft; then
    local rules policy
    rules="$(nft -j list ruleset)" \
      || die "无法读取现有 nftables 配置，防火墙尚未修改"
    policy="$(python3 -c '
import json
import sys

data = json.load(sys.stdin)
objects = data.get("nftables") if isinstance(data, dict) else None
if not isinstance(objects, list) or any(not isinstance(item, dict) for item in objects):
    raise SystemExit("invalid nftables ruleset")
for item in objects:
    if "rule" in item:
        print("preserve")
        raise SystemExit(0)
    chain = item.get("chain")
    if isinstance(chain, dict) and chain.get("hook") and chain.get("policy", "accept") != "accept":
        print("preserve")
        raise SystemExit(0)
print("empty")
' <<< "${rules}")" || die "无法解析现有 nftables 配置，防火墙尚未修改"
    if [ "${policy}" = "preserve" ]; then
      # Stopping nftables.service can flush rules owned by unrelated services.
      FIREWALL_PRESERVED=1
      warn "已保留现有 nftables 配置和防火墙服务状态；请按需放行 HashCake 端口"
      return 0
    fi
  fi
  arm_firewall_rollback
  disable_firewall_now
}

print_install_firewall_notice() {
  if [ "${FIREWALL_PRESERVED}" = "1" ]; then
    printf '%s\n' '提示: 已保留现有防火墙规则和服务状态；请在主机防火墙及云厂商安全组放行 HashCake 实际使用的端口。'
  else
    printf '%s\n' '提示: 整机防火墙已关闭并禁用；云厂商安全组仍需允许 HashCake 实际使用的端口。'
  fi
}

disable_firewall() {
  need_root
  acquire_installer_lock
  configure_install_firewall
  commit_firewall_change
}

public_ip() {
  local ip=""
  if command_exists curl; then
    ip="$(curl -fsS --connect-timeout 2 --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "${ip}" ] && command_exists hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "${ip:-服务器IP}"
}

format_url_host() {
  local host="$1"
  case "${host}" in
    \[*\]) printf '%s' "${host}" ;;
    *:*) printf '[%s]' "${host}" ;;
    *) printf '%s' "${host}" ;;
  esac
}

admin_url() {
  local scheme="http" host port
  case "${HTTPS_ACTIVE}" in true|1|yes|on) scheme="https" ;; esac
  host="$(host_from_bind "${ADMIN_BIND}")"
  port="$(bind_port "${ADMIN_BIND}")"
  case "${host}" in 0.0.0.0|::|\[::\]|"") host="$(public_ip)" ;; esac
  host="$(format_url_host "${host}")"
  printf '%s://%s:%s/%s/' "${scheme}" "${host}" "${port}" "${URL_PREFIX}"
}

bootstrap_admin_endpoint() {
  local host port
  host="$(host_from_bind "${ADMIN_BIND}")"
  port="$(bind_port "${ADMIN_BIND}")"
  case "${host}" in
    0.0.0.0) host="127.0.0.1" ;;
    ::|\[::\]) host="[::1]" ;;
    *) host="$(format_url_host "${host}")" ;;
  esac
  printf 'http://%s:%s/api/v1/bootstrap/confirm' "${host}" "${port}"
}

extract_bootstrap_token() {
  local file="${LOG_DIR}/hashcake.err.log" start_line="${1:-1}"
  [ -f "${file}" ] || return 1
  case "${start_line}" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  tail -n "+${start_line}" -- "${file}" | awk '
    /HashCake admin API bootstrap token/ { token = ""; capture = 1; remaining = 8; next }
    capture && remaining > 0 {
      remaining -= 1
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "" && line !~ /^=+$/) {
        token = line
        capture = 0
      }
    }
    END {
      if (token != "") print token
      else exit 1
    }
  '
}

wait_for_bootstrap_token() {
  local start_line="${1:-1}" attempt token
  for ((attempt = 0; attempt < 20; attempt += 1)); do
    token="$(extract_bootstrap_token "${start_line}" || true)"
    if [ -n "${token}" ]; then
      printf '%s' "${token}"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

confirm_initial_admin_token() {
  local token="$1" endpoint
  [ -n "${token}" ] || die "首次 Web访问令牌为空，无法完成后台初始化"
  endpoint="$(bootstrap_admin_endpoint)"
  python3 - "${endpoint}" 3<<<"${token}" <<'PY'
import sys
import time
import urllib.error
import urllib.request

endpoint = sys.argv[1]
with open(3, "r", encoding="utf-8", closefd=False) as token_fd:
    token = token_fd.read().strip()
if not token:
    raise SystemExit("bootstrap token is empty")

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
last_error = "service did not respond"
for _ in range(20):
    request = urllib.request.Request(
        endpoint,
        data=b"",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with opener.open(request, timeout=2) as response:
            if 200 <= response.status < 300:
                raise SystemExit(0)
            last_error = f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        last_error = f"HTTP {exc.code}"
        if exc.code in (400, 401, 403):
            break
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        last_error = str(exc)
    time.sleep(0.5)
raise SystemExit(f"bootstrap confirmation failed: {last_error}")
PY
}

download_repo_file() {
  local path="$1"
  local dst="$2"
  local args=(--fail --silent --show-error --location --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 600)
  local url part="${dst}.repo-download.$$"
  rm -f -- "${part}"
  if [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ] && [ -n "${RELEASE_MIRROR_BASE}" ]; then
    url="${RELEASE_MIRROR_BASE%/}/${path}"
    if curl "${args[@]}" "${url}" -o "${part}"; then
      mv -f -- "${part}" "${dst}"
      return 0
    fi
    rm -f -- "${part}"
    printf '注意: 国内发布镜像读取失败，尝试 GitHub 备用源\n' >&2
  fi
  url="https://api.github.com/repos/${RELEASE_REPO}/contents/${path}?ref=${RELEASE_BRANCH}"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl "${args[@]}" -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.raw" "${url}" -o "${part}"
  elif [ -n "${GH_TOKEN:-}" ]; then
    curl "${args[@]}" -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github.raw" "${url}" -o "${part}"
  else
    curl "${args[@]}" -H "Accept: application/vnd.github.raw" "${url}" -o "${part}"
  fi
  local status=$?
  if [ "${status}" -ne 0 ]; then
    rm -f -- "${part}"
    return "${status}"
  fi
  mv -f -- "${part}" "${dst}"
}

download_url_file() {
  local url="$1" dst="$2"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 600 \
    "${url}" -o "${dst}"
}

sha256_file() {
  local path="$1"
  if command_exists sha256sum; then
    sha256sum "${path}" | awk '{print tolower($1)}'
  elif command_exists shasum; then
    shasum -a 256 "${path}" | awk '{print tolower($1)}'
  else
    die "缺少 sha256sum 或 shasum，无法校验下载文件"
  fi
}

verify_file_sha256() {
  local path="$1" expected="$2" actual
  expected="$(printf '%s' "${expected}" | tr 'A-F' 'a-f')"
  actual="$(sha256_file "${path}")"
  if [ "${actual}" != "${expected}" ]; then
    printf '%s\n' "${red}错误:${reset} 下载文件 SHA-256 校验失败：期望 ${expected}，实际 ${actual}" >&2
    return 1
  fi
  ok "下载文件 SHA-256 校验通过"
}

# 锚点提交的清单：国内镜像按不可变提交取内容，不受分支清单缓存影响。国内服务器通常访问
# 不到 api.github.com，这个来源是「没有外网也要拿到至少锚点当时最新版」的最后一道兜底。
sums_lookup_mirror_anchor() {
  local dst="$1" base
  [ -n "${INSTALLER_ANCHOR_REF}" ] || return 1
  [ -n "${RELEASE_MIRROR_BASE}" ] || return 1
  case "${RELEASE_MIRROR_BASE}" in
    *@*) ;;
    *) return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  base="${RELEASE_MIRROR_BASE%/}"
  base="${base%@*}"
  curl --fail --silent --show-error --location --connect-timeout 5 --max-time 20 \
    "${base}@${INSTALLER_ANCHOR_REF}/${RELEASE_SUMS_PATH}" -o "${dst}" 2>/dev/null || return 1
  [ -s "${dst}" ]
}

# 国内镜像对 `@分支`（如 @main）的清单存在缓存窗口（`stale-while-revalidate` 以小时计）。
# 清单落后时，「最新稳定版」会被静默解析成上一个版本，甚至查不到目标版本的校验值；而下载和
# 校验都成功，所以不会触发任何回退。下面几个函数只解决这一件事：镜像清单缺失或落后时，
# best-effort 再要一份 GitHub 清单；拿不到（无外网、超时、限流）就维持镜像结果。
sums_lookup_github() {
  local dst="$1"
  command -v curl >/dev/null 2>&1 || return 1
  curl --fail --silent --show-error --location --connect-timeout 4 --max-time 8 \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${RELEASE_REPO}/contents/${RELEASE_SUMS_PATH}?ref=${RELEASE_BRANCH}" \
    -o "${dst}" 2>/dev/null || return 1
  [ -s "${dst}" ]
}

# 只有「清单取自国内镜像、且没有 GitHub token」时才需要上面那份兜底。
sums_mirror_may_be_stale() {
  [ -n "${RELEASE_MIRROR_BASE}" ] && [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ]
}

# 从清单里取某个资产的校验值；缺失或不是 64 位十六进制时输出空串。
sums_sha256_for() {
  local sums_file="$1" asset_path="$2" expected
  expected="$(awk -v wanted="${asset_path}" '$2 == wanted { print $1; exit }' "${sums_file}" 2>/dev/null || true)"
  expected="$(printf '%s' "${expected}" | tr 'A-F' 'a-f')"
  if [ "${#expected}" -ne 64 ] || [[ "${expected}" == *[!0-9a-f]* ]]; then
    return 0
  fi
  printf '%s' "${expected}"
}

# 从一份 SHA256SUMS 里挑出该平台的最新版本资产名；没有可选项时返回非 0。
latest_asset_from_sums() {
  local sums_file="$1" prefix="$2" names name=""
  [ -s "${sums_file}" ] || return 1
  names="$(awk -v platform="${RELEASE_PLATFORM}/" '
    index($2, platform) == 1 {
      name = $2
      sub(/^.*\//, "", name)
      print name
    }
  ' "${sums_file}" 2>/dev/null || true)"
  [ -n "${names}" ] || return 1
  if [ "${ALLOW_PRERELEASE}" = "1" ]; then
    name="$(printf '%s\n' "${names}" \
      | grep -E "^${prefix}-[0-9][0-9A-Za-z._-]*-${RELEASE_PLATFORM}$" \
      | sort -V \
      | tail -n 1 || true)"
  else
    name="$(printf '%s\n' "${names}" \
      | grep -E "^${prefix}-[0-9]+\.[0-9]+\.[0-9]+-${RELEASE_PLATFORM}$" \
      | sort -V \
      | tail -n 1 || true)"
  fi
  [ -n "${name}" ] || return 1
  printf '%s' "${name}"
}

# 候选版本是否比当前版本更新（入参是资产名，sort -V 直接按内嵌版本号比较）。
version_is_newer() {
  local candidate="$1" current="$2"
  [ "${candidate}" != "${current}" ] || return 1
  [ "$(printf '%s\n%s\n' "${current}" "${candidate}" | sort -V | tail -n 1)" = "${candidate}" ]
}

repo_asset_sha256() {
  local asset_path="$1" sums_file expected github_file anchor_file
  sums_file="$(mktemp "${INSTALL_DIR}/.SHA256SUMS.XXXXXX")"
  if ! download_repo_file "${RELEASE_SUMS_PATH}" "${sums_file}"; then
    rm -f -- "${sums_file}"
        die "发布仓库缺少可下载的 SHA256SUMS，已拒绝安装未经校验的官方二进制"
  fi
  expected="$(sums_sha256_for "${sums_file}" "${asset_path}")"
  if [ -z "${expected}" ] && sums_mirror_may_be_stale; then
    github_file="$(mktemp "${INSTALL_DIR}/.SHA256SUMS.github.XXXXXX")"
    if sums_lookup_github "${github_file}"; then
      expected="$(sums_sha256_for "${github_file}" "${asset_path}")"
      [ -z "${expected}" ] || printf '%s\n' "${yellow}注意:${reset} 国内镜像的发布清单尚未刷新，${asset_path} 的校验值取自 GitHub" >&2
    fi
    rm -f -- "${github_file}"
    if [ -z "${expected}" ]; then
      anchor_file="$(mktemp "${INSTALL_DIR}/.SHA256SUMS.anchor.XXXXXX")"
      if sums_lookup_mirror_anchor "${anchor_file}"; then
        expected="$(sums_sha256_for "${anchor_file}" "${asset_path}")"
        [ -z "${expected}" ] || printf '%s\n' "${yellow}注意:${reset} 国内镜像的分支清单尚未刷新，${asset_path} 的校验值取自锚点提交的清单" >&2
      fi
      rm -f -- "${anchor_file}"
    fi
  fi
  rm -f -- "${sums_file}"
  if [ -z "${expected}" ]; then
    die "SHA256SUMS 中缺少 ${asset_path} 的有效校验值"
  fi
  printf '%s' "${expected}"
}

repo_asset_sha256_optional() {
  local asset_path="$1" sums_file expected github_file anchor_file
  sums_file="$(mktemp "${INSTALL_DIR}/.SHA256SUMS.XXXXXX")"
  if ! download_repo_file "${RELEASE_SUMS_PATH}" "${sums_file}"; then
    rm -f -- "${sums_file}"
    return 1
  fi
  expected="$(sums_sha256_for "${sums_file}" "${asset_path}")"
  if [ -z "${expected}" ] && sums_mirror_may_be_stale; then
    github_file="$(mktemp "${INSTALL_DIR}/.SHA256SUMS.github.XXXXXX")"
    if sums_lookup_github "${github_file}"; then
      expected="$(sums_sha256_for "${github_file}" "${asset_path}")"
    fi
    rm -f -- "${github_file}"
    if [ -z "${expected}" ]; then
      anchor_file="$(mktemp "${INSTALL_DIR}/.SHA256SUMS.anchor.XXXXXX")"
      if sums_lookup_mirror_anchor "${anchor_file}"; then
        expected="$(sums_sha256_for "${anchor_file}" "${asset_path}")"
      fi
      rm -f -- "${anchor_file}"
    fi
  fi
  rm -f -- "${sums_file}"
  [ -n "${expected}" ] || return 1
  printf '%s' "${expected}"
}

asset_name_for_version() {
  local prefix="$1"
  if [ "${RELEASE_TAG}" != "latest" ]; then
    printf '%s-%s-%s' "${prefix}" "${RELEASE_TAG#v}" "${RELEASE_PLATFORM}"
    return
  fi
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法查询 latest Release"
  local sums_file name github_file github_name anchor_file anchor_name
  sums_file="$(mktemp "${TMPDIR:-/tmp}/hashcake-SHA256SUMS.XXXXXX")"
  if ! download_repo_file "${RELEASE_SUMS_PATH}" "${sums_file}"; then
    rm -f -- "${sums_file}"
    die "无法读取 ${RELEASE_REPO}/${RELEASE_SUMS_PATH}，无法确定最新官方版本"
  fi
  name="$(latest_asset_from_sums "${sums_file}" "${prefix}" || true)"
  rm -f -- "${sums_file}"
  [ -n "${name}" ] || die "无法在 ${RELEASE_REPO}/${RELEASE_SUMS_PATH} 找到 ${prefix} 的发布文件；可改用 HASHCAKE_DOWNLOAD_URL"

  # 镜像清单落后时，按 GitHub 清单里更新的那个版本走；下载路径仍是镜像优先。
  if sums_mirror_may_be_stale; then
    github_file="$(mktemp "${TMPDIR:-/tmp}/hashcake-GitHub-SHA256SUMS.XXXXXX")"
    if sums_lookup_github "${github_file}"; then
      github_name="$(latest_asset_from_sums "${github_file}" "${prefix}" || true)"
      if [ -n "${github_name}" ] && version_is_newer "${github_name}" "${name}"; then
        printf '%s\n' "${yellow}注意:${reset} 国内镜像的发布清单尚未刷新（镜像最新 ${name}，GitHub 最新 ${github_name}），已按 GitHub 清单选择版本；下载仍优先使用国内镜像" >&2
        name="${github_name}"
      fi
    fi
    rm -f -- "${github_file}"
  fi

  # 国内服务器通常访问不到 api.github.com，锚点提交的不可变清单是这一侧的兜底来源。
  if sums_mirror_may_be_stale; then
    anchor_file="$(mktemp "${TMPDIR:-/tmp}/hashcake-Anchor-SHA256SUMS.XXXXXX")"
    if sums_lookup_mirror_anchor "${anchor_file}"; then
      anchor_name="$(latest_asset_from_sums "${anchor_file}" "${prefix}" || true)"
      if [ -n "${anchor_name}" ] && version_is_newer "${anchor_name}" "${name}"; then
        printf '%s\n' "${yellow}注意:${reset} 国内镜像的分支清单尚未刷新（镜像最新 ${name}，锚点提交清单最新 ${anchor_name}），已按锚点清单选择版本；下载仍优先使用国内镜像" >&2
        name="${anchor_name}"
      fi
    fi
    rm -f -- "${anchor_file}"
  fi
  printf '%s' "${name}"
}

ensure_config_dir() {
  local managed=0 owner_uid service_uid mode
  [ "${CONFIG_DIR}" != "${INSTALL_DIR}" ] \
    || die "配置文件必须放在独立子目录中，不能直接放在安装目录：${CONFIG_FILE}"
  [ ! -L "${CONFIG_DIR}" ] || die "配置目录不能是符号链接：${CONFIG_DIR}"
  case "${CONFIG_DIR}" in
    "${INSTALL_DIR}/config") managed=1 ;;
  esac

  if [ ! -e "${CONFIG_DIR}" ]; then
    validate_root_controlled_parent "${CONFIG_DIR}" "配置目录"
    install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" "${CONFIG_DIR}"
  fi
  [ -d "${CONFIG_DIR}" ] || die "配置目录路径不是目录：${CONFIG_DIR}"

  service_uid="$(id -u "${SERVICE_USER}")"
  owner_uid="$(stat -c '%u' -- "${CONFIG_DIR}")"
  if [ "${owner_uid}" != "${service_uid}" ]; then
    if [ "${managed}" = "1" ]; then
      chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_DIR}"
    else
      die "自定义配置目录必须属于 ${SERVICE_USER}，以便 Web 后台原子保存配置：${CONFIG_DIR}"
    fi
  fi
  mode="$(stat -c '%a' -- "${CONFIG_DIR}")"
  if [ $((8#${mode} & 8#002)) -ne 0 ]; then
    die "配置目录不能被其他用户写入：${CONFIG_DIR}"
  fi
  chmod 750 "${CONFIG_DIR}"
}

ensure_dirs() {
  need_root
  reject_space_path
  ensure_service_user
  [ ! -L "${INSTALL_DIR}" ] || die "安装目录不能是符号链接：${INSTALL_DIR}"
  [ ! -L "${STATE_DIR}" ] || die "状态目录不能是符号链接：${STATE_DIR}"
  [ ! -L "${LOG_DIR}" ] || die "日志目录不能是符号链接：${LOG_DIR}"
  [ ! -L "${BACKUP_DIR}" ] || die "备份目录不能是符号链接：${BACKUP_DIR}"
  mkdir -p "${INSTALL_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  chmod 755 "${INSTALL_DIR}"
  chmod 700 "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  chown root:root "${INSTALL_DIR}" "${BACKUP_DIR}"
  chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${STATE_DIR}" "${LOG_DIR}"
  ensure_config_dir
  ensure_installer_state_dir
}

validate_root_controlled_parent() {
  local path="$1" label="$2" parent mode
  parent="$(dirname -- "${path}")"
  [ ! -L "${parent}" ] || die "${label}所在目录不能是符号链接：${parent}"
  [ -d "${parent}" ] || die "${label}所在目录不存在：${parent}"
  [ "$(stat -c '%u' -- "${parent}")" = "0" ] || die "${label}所在目录必须属于 root：${parent}"
  mode="$(stat -c '%a' -- "${parent}")"
  if [ $((8#${mode} & 8#022)) -ne 0 ]; then
    die "${label}所在目录不能被 group/other 写入：${parent}"
  fi
}

ensure_metrics_token() {
  local token_file="${STATE_DIR}/metrics-token"
  command_exists python3 || die "缺少 python3，无法安全创建 ${token_file}"
  run_as_service_user python3 - "${token_file}" <<'PY'
import os
import secrets
import stat
import sys
import tempfile

path = sys.argv[1]
try:
    current = os.lstat(path)
except FileNotFoundError:
    current = None
if current is not None:
    if stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode):
        raise SystemExit(f"unsafe metrics token path: {path}")
    if current.st_size > 0:
        os.chmod(path, 0o600)
        raise SystemExit(0)

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".metrics-token.", dir=directory)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as fh:
        fh.write(secrets.token_hex(32))
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

write_default_config() {
  cat > "${CONFIG_FILE}" <<'YAML'
bind: "0.0.0.0"
max_debt_seconds: 600
reload_interval_secs: 2
legacy_plaintext_ingress: true

tunnel:
  ingress:
    listen: "127.0.0.1:18443"

ports: []
YAML
}

install_config() {
  [ "$(dirname -- "${CONFIG_FILE}")" = "${CONFIG_DIR}" ] \
    || die "配置目录与配置文件路径不一致：${CONFIG_FILE}"
  ensure_config_dir
  [ ! -L "${CONFIG_FILE}" ] || die "配置文件不能是符号链接：${CONFIG_FILE}"
  if [ -e "${CONFIG_FILE}" ] && [ ! -f "${CONFIG_FILE}" ]; then
    die "配置文件路径不是普通文件：${CONFIG_FILE}"
  fi
  if [ -f "${CONFIG_FILE}" ]; then
    chmod 600 "${CONFIG_FILE}"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
    ok "保留已有配置 ${CONFIG_FILE}"
    return
  fi

  if [ "${CONFIG_FILE}" = "${INSTALL_DIR}/config/hashcake.yaml" ] && [ -f "${LEGACY_CONFIG_FILE}" ]; then
    [ ! -L "${LEGACY_CONFIG_FILE}" ] || die "旧配置文件不能是符号链接：${LEGACY_CONFIG_FILE}"
    install -m 0600 "${LEGACY_CONFIG_FILE}" "${CONFIG_FILE}"
    ok "已把旧配置迁移到可由 Web 后台安全保存的新目录 ${CONFIG_FILE}"
    warn "旧配置 ${LEGACY_CONFIG_FILE} 仅保留为备份；后续请编辑新路径"
  elif [ -f "${SOURCE_ROOT}/hashcake.yaml" ]; then
    install -m 0600 "${SOURCE_ROOT}/hashcake.yaml" "${CONFIG_FILE}"
    ok "已复制配置到 ${CONFIG_FILE}"
  else
    write_default_config
    chmod 600 "${CONFIG_FILE}"
    ok "已生成可直接启动的默认配置（暂未启用矿机端口，可在 Web 后台按需添加）"
  fi
  chmod 600 "${CONFIG_FILE}"
  chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
}

build_spa_if_needed() {
  case ",${BUILD_FEATURES}," in
    *,admin-spa,*)
      [ -d "${SOURCE_ROOT}/hashcake/web" ] || die "缺少 hashcake/web，无法构建 admin-spa"
      command -v pnpm >/dev/null 2>&1 || die "缺少 pnpm，无法构建 Web 管理后台"
      log "构建 Web 管理后台"
      if [ -f "${SOURCE_ROOT}/hashcake/web/pnpm-lock.yaml" ]; then
        pnpm --dir "${SOURCE_ROOT}/hashcake/web" install --frozen-lockfile
      else
        pnpm --dir "${SOURCE_ROOT}/hashcake/web" install
      fi
      pnpm --dir "${SOURCE_ROOT}/hashcake/web" build
      ;;
  esac
}

build_hashcake() {
  [ -f "${SOURCE_ROOT}/Cargo.toml" ] || die "当前脚本不在源码仓库内；请设置 HASHCAKE_BIN_SOURCE 或 HASHCAKE_DOWNLOAD_URL"
  command -v cargo >/dev/null 2>&1 || die "缺少 cargo，无法从源码构建"
  build_spa_if_needed
  log "构建 hashcake release 二进制"
  if [ -n "${BUILD_FEATURES}" ]; then
    cargo build --release -p hashcake --bin hashcake --features "${BUILD_FEATURES}"
  else
    cargo build --release -p hashcake --bin hashcake
  fi
}

download_hashcake() {
  local dst="$1" manifest_dst="$2" download_path="${1}.download" expected_sha=""
  local manifest_download="${2}.download" manifest_sha="" manifest_asset=""
  local url="${HASHCAKE_DOWNLOAD_URL:-}"
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 HASHCAKE_DOWNLOAD_URL"
  if [ -z "${url}" ]; then
    case "$(uname -s):$(uname -m)" in
      Linux:x86_64|Linux:amd64) ;;
      *) return 1 ;;
    esac
    local asset
    if ! asset="$(asset_name_for_version hashcake)"; then
      die "无法确定要安装的 HashCake 发布文件"
    fi
    EXPECTED_BINARY_VERSION="${asset#hashcake-}"
    EXPECTED_BINARY_VERSION="${EXPECTED_BINARY_VERSION%-"${RELEASE_PLATFORM}"}"
    log "下载 hashcake 二进制：github.com/${RELEASE_REPO}/${RELEASE_PLATFORM}/${asset}"
    if ! download_repo_file "${RELEASE_PLATFORM}/${asset}" "${download_path}"; then
      rm -f -- "${download_path}"
      die "下载 HashCake 发布文件失败"
    fi
    if ! expected_sha="$(repo_asset_sha256 "${RELEASE_PLATFORM}/${asset}")"; then
      rm -f -- "${download_path}"
      die "无法取得 HashCake 发布文件的 SHA-256 校验值"
    fi
    manifest_asset="${asset}.manifest.json"
    if manifest_sha="$(repo_asset_sha256_optional "${RELEASE_PLATFORM}/${manifest_asset}")"; then
      if ! download_repo_file "${RELEASE_PLATFORM}/${manifest_asset}" "${manifest_download}"; then
        rm -f -- "${download_path}" "${manifest_download}"
        die "signed manifest 已列入 SHA256SUMS，但下载失败"
      fi
    fi
  else
    log "从自定义 HASHCAKE_DOWNLOAD_URL 下载 hashcake 二进制（地址已隐藏）"
    if ! download_url_file "${url}" "${download_path}"; then
      rm -f -- "${download_path}"
      die "下载 HASHCAKE_DOWNLOAD_URL 失败"
    fi
    expected_sha="${DOWNLOAD_SHA256}"
    if [ -z "${expected_sha}" ]; then
      warn "自定义 HASHCAKE_DOWNLOAD_URL 未提供 HASHCAKE_DOWNLOAD_SHA256，只能执行二进制启动检查"
    fi
    if [ -n "${MANIFEST_URL}" ]; then
      if ! download_url_file "${MANIFEST_URL}" "${manifest_download}"; then
        rm -f -- "${download_path}" "${manifest_download}"
        die "下载 HASHCAKE_MANIFEST_URL 失败"
      fi
      manifest_sha="${DOWNLOAD_MANIFEST_SHA256}"
      [ -n "${manifest_sha}" ] \
        || warn "自定义 manifest 未提供 HASHCAKE_MANIFEST_SHA256，将由候选二进制执行签名验证"
    fi
  fi
  if [ -n "${expected_sha}" ] && ! verify_file_sha256 "${download_path}" "${expected_sha}"; then
    rm -f -- "${download_path}"
    die "HashCake 下载文件校验失败，候选文件已删除"
  fi
  if [ -f "${manifest_download}" ] && [ -n "${manifest_sha}" ] \
    && ! verify_file_sha256 "${manifest_download}" "${manifest_sha}"; then
    rm -f -- "${download_path}" "${manifest_download}"
    die "HashCake manifest 下载校验失败"
  fi
  if ! install -m 0755 "${download_path}" "${dst}"; then
    rm -f -- "${download_path}"
    die "无法准备 HashCake 候选二进制"
  fi
  if [ -f "${manifest_download}" ]; then
    install -m 0644 "${manifest_download}" "${manifest_dst}" \
      || { rm -f -- "${download_path}" "${manifest_download}"; die "无法准备 HashCake 候选 manifest"; }
  fi
  rm -f -- "${download_path}" "${manifest_download}"
  return 0
}

# 用**候选**二进制校验**已部署的配置**。必须在 `mv -fT` 顶掉旧二进制之前跑。
#
# 存在的理由：配置校验是 fail-closed 的（例如端口重复会直接拒绝启动）。没有这一步
# 时，一份旧版本能带病运行的配置会走成「停服务 → 新进程起不来 → 事务回滚」，中间
# 矿机实打实地断一次；若 START_AFTER_INSTALL=0，新二进制还会被提交，故障推迟到下次
# 人工启动才暴露。
#
# 为什么必须在 mv 之前、而不是装完再检：`mv` 的下一行就是 `TXN_BINARY_CHANGED=1`，
# 而 rollback_install_transaction 见到该标志会先 `systemctl stop` 再还原、再重启 ——
# 那样即使检出问题也已经断了一次矿机。放在 mv 前，失败时两个 changed 标志都还是 0，
# 回滚不会碰服务，旧二进制与运行中的进程全程未被触碰。
#
# 用 run_as_service_user 而非 root 执行：顺带验证守护进程的真实身份读得到这份配置。
#
# **边界**：它只回答「这份 YAML 能否通过 Config::validate」，不等于「新进程一定能
# 起来」。守护进程启动路径还会校验客户材料、初始化 miner TLS 等资源，那些失败本命令
# 看不到。同样地，本检查与真正的重启之间还隔着写 service、防火墙等步骤，其间管理面或
# 手工编辑仍可改配置——这个窗口没有被消除，只是被大幅收窄。
assert_config_accepted_by_candidate() {
  local candidate_bin="$1" probe_output
  # 本函数在 install_config 之后调用，配置此刻必须存在。缺文件不是「正常跳过」而是
  # 不变量被破坏（竞态或前面的步骤没写成功），放行等于把问题推给重启后的进程。
  [ -f "${CONFIG_FILE}" ] \
    || die "配置文件 ${CONFIG_FILE} 在写入后消失，已中止本次变更"
  # 能力探测走**正向**匹配顶层帮助，而不是「check-config 执行失败就当作旧版本」——
  # 后者会把子命令自身的任何异常（panic、依赖缺失、被 seccomp 拦下）一并解释成
  # 「不支持」而静默放行。`--version` 已在上面跑通，所以 `--help` 再失败属于真故障。
  local help_output
  help_output="$(run_hashcake_as_service_user "${candidate_bin}" --help 2>&1)" \
    || die "候选 HashCake 二进制无法输出帮助信息，已中止本次变更"
  case "${help_output}" in
    *check-config*) ;;
    *)
      warn "候选 HashCake 二进制不含 check-config 子命令（版本回退），跳过变更前配置预检"
      return 0
      ;;
  esac
  if ! probe_output="$(run_hashcake_as_service_user "${candidate_bin}" check-config --config "${CONFIG_FILE}" 2>&1)"; then
    printf '%s\n' "${probe_output}" >&2
    return 1
  fi
  printf '%s\n' "${probe_output}"
}

extract_hashcake_version() {
  printf '%s\n' "$1" \
    | awk '$1 == "hashcake" && NF == 2 { print $2; exit }'
}

install_binary() {
  local src="${HASHCAKE_BIN_SOURCE:-}" candidate_dir candidate candidate_manifest
  local source_manifest source_label version_output actual_version
  EXPECTED_BINARY_VERSION=""
  if [ "${RELEASE_TAG}" != "latest" ]; then
    EXPECTED_BINARY_VERSION="${RELEASE_TAG#v}"
  fi
  validate_root_controlled_parent "${BIN_PATH}" "HashCake 二进制"
  [ ! -L "${BIN_PATH}" ] || die "HashCake 二进制不能是符号链接：${BIN_PATH}"
  if [ -e "${BIN_PATH}" ] && [ ! -f "${BIN_PATH}" ]; then
    die "HashCake 二进制路径不是普通文件：${BIN_PATH}"
  fi
  validate_root_controlled_parent "${MANIFEST_PATH}" "HashCake manifest"
  candidate_dir="$(mktemp -d "${INSTALL_DIR}/.hashcake-candidate.XXXXXX")"
  INSTALL_CANDIDATE_DIR="${candidate_dir}"
  chmod 0755 "${candidate_dir}"
  candidate="${candidate_dir}/hashcake"
  candidate_manifest="${candidate}.manifest.json"
  if [ -n "${src}" ]; then
    [ -x "${src}" ] || { rm -rf -- "${candidate_dir}"; die "HASHCAKE_BIN_SOURCE 不存在或不可执行：${src}"; }
    [ ! -L "${src}" ] || { rm -rf -- "${candidate_dir}"; die "HASHCAKE_BIN_SOURCE 不能是符号链接：${src}"; }
    install -m 0755 "${src}" "${candidate}"
    source_manifest="${HASHCAKE_MANIFEST_SOURCE:-${src}.manifest.json}"
    if [ -n "${HASHCAKE_MANIFEST_SOURCE:-}" ] && [ ! -f "${source_manifest}" ]; then
      rm -rf -- "${candidate_dir}"
      die "HASHCAKE_MANIFEST_SOURCE 不存在：${source_manifest}"
    fi
    if [ -f "${source_manifest}" ]; then
      [ ! -L "${source_manifest}" ] || { rm -rf -- "${candidate_dir}"; die "HashCake manifest 不能是符号链接"; }
      install -m 0644 "${source_manifest}" "${candidate_manifest}"
    fi
    source_label="指定二进制"
  elif download_hashcake "${candidate}" "${candidate_manifest}"; then
    source_label="下载的二进制"
  else
    build_hashcake
    install -m 0755 "${SOURCE_ROOT}/target/release/hashcake" "${candidate}"
    source_label="源码构建二进制"
  fi

  chown root:root "${candidate}"
  if [ -f "${candidate_manifest}" ]; then
    chmod 0644 "${candidate_manifest}"
    chown root:root "${candidate_manifest}"
  fi
  if command_exists timeout; then
    if ! version_output="$(run_hashcake_as_service_user timeout 15 "${candidate}" --version 2>&1)"; then
      rm -rf -- "${candidate_dir}"
      die "HashCake 候选二进制无法正常执行，防火墙尚未修改。原始错误：
${version_output:-未返回错误详情。请检查 CPU 架构和 GLIBC 版本。}"
    fi
  else
    if ! version_output="$(run_hashcake_as_service_user "${candidate}" --version 2>&1)"; then
      rm -rf -- "${candidate_dir}"
      die "HashCake 候选二进制无法正常执行，防火墙尚未修改。原始错误：
${version_output:-未返回错误详情。请检查 CPU 架构和 GLIBC 版本。}"
    fi
  fi
  [ -n "${version_output}" ] \
    || { rm -rf -- "${candidate_dir}"; die "HashCake 候选二进制执行成功但没有返回版本号"; }
  actual_version="$(extract_hashcake_version "${version_output}")"
  [ -n "${actual_version}" ] \
    || { rm -rf -- "${candidate_dir}"; die "HashCake 候选二进制没有返回有效的 hashcake <版本号> 输出"; }
  if [ -n "${EXPECTED_BINARY_VERSION}" ] && [ "${actual_version}" != "${EXPECTED_BINARY_VERSION}" ]; then
    rm -rf -- "${candidate_dir}"
    die "HashCake 候选二进制版本不匹配：期望 ${EXPECTED_BINARY_VERSION}，实际 ${actual_version:-未知}"
  fi
  # 最后一道门：候选二进制必须接受当前已落盘的配置。放在 mv 之前，失败时旧二进制
  # 原封未动、服务全程不被停。与上面几处候选失败一样清理临时文件再 die。
  #
  # 修复指引必须是「先停服务再改配置」，不能是「保持运行、在线改」：如果现网配置是
  # 重复端口，旧版本的热重载正是本次要修的那个 bug —— 运维一保存 YAML，旧进程 diff
  # 就会为被删掉的那条产出 Removed，当场拆掉在线端口。让运维在不知情的情况下触发它，
  # 比这次升级失败本身更糟。
  if ! assert_config_accepted_by_candidate "${candidate}"; then
    rm -rf -- "${candidate_dir}"
    die "新版本拒绝当前配置 ${CONFIG_FILE}；已中止本次变更，旧二进制与运行中的服务均未改动。
修复步骤（请按顺序，不要在服务运行时直接改配置）：
  1) systemctl stop ${SERVICE_NAME}
  2) 按上方提示修正 ${CONFIG_FILE}
  3) 重新执行本次更新
当前运行的旧版本对这类配置错误存在已知的热重载缺陷：在线保存配置可能立即断开该端口上的矿机。"
  fi
  [ "${INSTALL_TRANSACTION_ACTIVE}" = "1" ] \
    || { rm -rf -- "${candidate_dir}"; die "二进制/manifest 替换必须在安装事务内执行"; }
  if has_systemd && systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    log "候选文件已通过预检，停止服务后成组替换 binary + manifest"
    systemctl stop "${SERVICE_NAME}.service" \
      || { rm -rf -- "${candidate_dir}"; die "无法停止 ${SERVICE_NAME}.service，未替换发布文件"; }
  fi
  if [ -f "${candidate_manifest}" ]; then
    TXN_MANIFEST_CHANGED=1
    mv -fT "${candidate_manifest}" "${MANIFEST_PATH}"
    chmod 0644 "${MANIFEST_PATH}"
    chown root:root "${MANIFEST_PATH}"
  elif [ -e "${MANIFEST_PATH}" ]; then
    TXN_MANIFEST_CHANGED=1
    rm -f -- "${MANIFEST_PATH}"
  fi
  TXN_BINARY_CHANGED=1
  mv -fT "${candidate}" "${BIN_PATH}"
  chmod 755 "${BIN_PATH}"
  chown root:root "${BIN_PATH}"
  rm -rf -- "${candidate_dir}"
  INSTALL_CANDIDATE_DIR=""
  ok "已成组安装${source_label} binary + manifest（hashcake ${actual_version}）"
}

write_service() {
  local persist_security_now="${1:-1}"
  need_root
  has_systemd || die "当前系统没有可用 systemd，暂不写入服务"
  require_hardened_systemd
  case "${persist_security_now}" in
    0|1) ;;
    *) die "write_service 的安全配置写入参数只能是 0 或 1" ;;
  esac
  [ -n "${ADMIN_BIND}" ] || die "管理后台监听地址为空"
  validate_saved_admin_bind "${ADMIN_BIND}"
  URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  if [ "${persist_security_now}" = "1" ]; then
    persist_admin_security
  fi
  save_install_env
  chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
  validate_root_controlled_parent "${SERVICE_FILE}" "systemd 服务文件"
  [ ! -L "${SERVICE_FILE}" ] || die "systemd 服务文件不能是符号链接：${SERVICE_FILE}"
  if [ -e "${SERVICE_FILE}" ] && [ ! -f "${SERVICE_FILE}" ]; then
    die "systemd 服务路径不是普通文件：${SERVICE_FILE}"
  fi

  local admin_args="" service_tmp
  if [ "${ADMIN_BIND}" != "off" ] && [ -n "${ADMIN_BIND}" ]; then
    admin_args=" --admin-bind ${ADMIN_BIND} --admin-token-store ${STATE_DIR}/admin.json --admin-audit-db ${STATE_DIR}/admin-audit.sqlite --metrics-token-file ${STATE_DIR}/metrics-token"
  fi
  local update_args="" unit_update_url
  if [ -n "${UPDATE_MANIFEST_URL}" ]; then
    unit_update_url="${UPDATE_MANIFEST_URL//%/%%}"
    update_args=" --update-manifest-url ${unit_update_url}"
  fi

  service_tmp="$(mktemp "/etc/systemd/system/.${SERVICE_NAME}.XXXXXX.service")"
  cat > "${service_tmp}" <<EOF
[Unit]
Description=HashCake Stratum Proxy
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment="RUST_LOG=${RUST_LOG_VALUE}"
Environment="HASHCAKE_ENVELOPE_EXEC_DIR=${STATE_DIR}"
ExecStart=${BIN_PATH} --config ${CONFIG_FILE} --no-tui --token-store ${STATE_DIR}/tokens.json --log-dir ${LOG_DIR} --log-file-prefix hashcake-debug.log${admin_args}${update_args}
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=1048576
LimitCORE=0
MemorySwapMax=0
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadOnlyPaths=${BIN_PATH} -${MANIFEST_PATH}
ReadWritePaths=${CONFIG_DIR} ${STATE_DIR} ${LOG_DIR}
StandardOutput=append:${LOG_DIR}/hashcake.service.log
StandardError=append:${LOG_DIR}/hashcake.err.log

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${service_tmp}"
  chown root:root "${service_tmp}"
  if command_exists systemd-analyze; then
    if ! systemd-analyze verify "${service_tmp}" >/dev/null; then
      rm -f -- "${service_tmp}"
      die "systemd 服务校验失败，防火墙尚未修改"
    fi
  fi
  TXN_SERVICE_CHANGED=1
  mv -fT "${service_tmp}" "${SERVICE_FILE}"
  systemctl daemon-reload
  ok "已写入 systemd 服务 ${SERVICE_FILE}"
}

print_install_result() {
  local token="${FIRST_WEB_TOKEN:-}"
  cat <<EOF

========== HashCake 安装结果 ==========
当前版本: $([ -x "${BIN_PATH}" ] && run_hashcake_as_service_user "${BIN_PATH}" --version 2>/dev/null || printf '未知')
后台访问地址: $(admin_url)
EOF
  if [ -n "${token}" ]; then
    cat <<EOF
首次 Web访问令牌: ${token}
有效期: ${BOOTSTRAP_TTL_MINUTES} 分钟
用途: 仅用于创建首个管理员账号；账号创建成功后立即失效
EOF
  else
    cat <<EOF
首次 Web访问令牌: 未生成新令牌（已沿用现有管理员凭据）
EOF
  fi
  cat <<EOF
安全访问路径: /${URL_PREFIX}/
HTTPS: ${HTTPS_ACTIVE}
EOF
  print_install_firewall_notice
  case "${HTTPS_ACTIVE}" in
    true|1|yes|on) warn "当前使用自签 HTTPS 证书，浏览器首次访问提示不受信任是预期行为" ;;
  esac
}

install_service() {
  local admin_state needs_bootstrap=0 bootstrap_log_start=1 token=""
  preflight_install_or_update
  prepare_install_transaction_environment
  if is_complete_install; then
    die "检测到已安装 HashCake，请使用 update 更新程序"
  fi
  if is_installed; then
    warn "检测到上次未完成的安装文件，将在事务保护下继续修复首次安装"
  fi
  check_no_running_conflict
  begin_install_transaction
  configure_web_defaults_for_install
  validate_admin_bind_for_install
  ensure_metrics_token
  install_config
  install_binary
  admin_state="$(admin_store_state)"
  case "${admin_state}" in
    missing|uninitialized)
      needs_bootstrap=1
      rm -f -- "${STATE_DIR}/admin.json"
      write_service 0
      ;;
    provisioned) write_service ;;
    *) die "无法识别后台状态：${admin_state}" ;;
  esac
  systemctl enable "${SERVICE_NAME}.service"
  configure_install_firewall
  if [ "${needs_bootstrap}" = "1" ]; then
    if [ -f "${LOG_DIR}/hashcake.err.log" ]; then
      bootstrap_log_start=$(( $(wc -l < "${LOG_DIR}/hashcake.err.log") + 1 ))
    fi
    log "首次启动 HashCake 并初始化 Web 管理员令牌"
    if ! restart_service_checked; then
      systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
      die "${SERVICE_NAME}.service 首次启动失败或未能稳定运行"
    fi
    token="$(wait_for_bootstrap_token "${bootstrap_log_start}")" \
      || die "服务已启动，但未能从本次启动日志提取首次 Web访问令牌"
    confirm_initial_admin_token "${token}" \
      || die "首次 Web访问令牌自动确认失败"
    FIRST_WEB_TOKEN="${token}"
    persist_admin_security
    ok "已确认首次 Web访问令牌并写入最终 HTTPS 与安全访问路径"
  fi
  if [ "${START_AFTER_INSTALL}" = "1" ]; then
    restart_service 0
  else
    stop_service
    ok "已安装，未自动启动"
  fi
  commit_install_transaction
  print_install_result
}

update_service() {
  preflight_install_or_update
  prepare_install_transaction_environment
  is_installed || die "未检测到已安装 HashCake，请先执行 install 首次安装"
  begin_install_transaction
  configure_web_defaults_for_update
  ensure_metrics_token
  install_config
  install_binary
  write_service
  systemctl enable "${SERVICE_NAME}.service"
  configure_install_firewall
  if [ "${START_AFTER_INSTALL}" = "1" ]; then
    restart_service 0
  else
    stop_service
    ok "已更新，未自动启动"
  fi
  commit_install_transaction
  cat <<EOF

========== HashCake 更新结果 ==========
当前版本: $([ -x "${BIN_PATH}" ] && run_hashcake_as_service_user "${BIN_PATH}" --version 2>/dev/null || printf '未知')
后台访问地址: $(admin_url)
安全访问路径: /${URL_PREFIX}/
提示: 更新已保留 Web 端口、安全访问路径、账号、令牌、配置和状态目录。
EOF
  print_install_firewall_notice
}

start_service() {
  restart_service
}

stop_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  systemctl stop "${SERVICE_NAME}.service" \
    || die "无法停止 ${SERVICE_NAME}.service"
  if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    die "${SERVICE_NAME}.service 停止后仍处于 active 状态"
  fi
  ok "已停止 ${SERVICE_NAME}"
}

restart_service_checked() {
  local restarts_baseline restarts_first restarts_second pid_first pid_second
  systemctl daemon-reload || return 1
  systemctl reset-failed "${SERVICE_NAME}.service" || return 1
  systemctl restart "${SERVICE_NAME}.service" || return 1
  restarts_baseline="$(systemctl show "${SERVICE_NAME}.service" -p NRestarts --value)" || return 1
  [ "${restarts_baseline}" = "0" ] || return 1
  sleep 2
  if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    return 1
  fi
  restarts_first="$(systemctl show "${SERVICE_NAME}.service" -p NRestarts --value)" || return 1
  pid_first="$(systemctl show "${SERVICE_NAME}.service" -p MainPID --value)" || return 1
  [ "${restarts_first}" = "0" ] || return 1
  [[ "${pid_first}" =~ ^[0-9]+$ ]] && [ "${pid_first}" -gt 0 ] || return 1
  sleep 2
  if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    return 1
  fi
  restarts_second="$(systemctl show "${SERVICE_NAME}.service" -p NRestarts --value)" || return 1
  pid_second="$(systemctl show "${SERVICE_NAME}.service" -p MainPID --value)" || return 1
  [ "${restarts_second}" = "0" ] || return 1
  [ "${pid_second}" = "${pid_first}" ] || return 1
}

service_exec_directory_matches() {
  local environment unset_environment
  environment="$(systemctl show "${SERVICE_NAME}.service" -p Environment --value)" \
    || die "无法读取服务启动环境"
  unset_environment="$(systemctl show "${SERVICE_NAME}.service" -p UnsetEnvironment --value)" \
    || die "无法读取服务环境排除项"
  python3 - "${STATE_DIR}" "${environment}" "${unset_environment}" <<'PY'
import shlex
import sys

key = "HASHCAKE_ENVELOPE_EXEC_DIR"
values = dict(item.split("=", 1) for item in shlex.split(sys.argv[2]) if "=" in item)
unset = shlex.split(sys.argv[3])
raise SystemExit(0 if values.get(key) == sys.argv[1] and key not in unset
                 and key + "=" + sys.argv[1] not in unset else 1)
PY
}

prepare_installed_service() {
  require_bash_runtime
  reject_space_path
  validate_runtime_inputs
  require_command python3
  require_command timeout
  acquire_installer_lock
  is_complete_install || die "HashCake 安装不完整，请先修复本地程序和服务文件"
  validate_root_controlled_parent "${SERVICE_FILE}" "systemd 服务文件"
  [ ! -L "${SERVICE_FILE}" ] && [ "$(stat -c '%u' -- "${SERVICE_FILE}")" = "0" ] \
    && [ $((8#$(stat -c '%a' -- "${SERVICE_FILE}") & 8#022)) -eq 0 ] \
    || die "服务文件必须由 root 管理且不能是符号链接或被其他用户写入"
  systemctl daemon-reload
  local actual_user actual_group actual_home fragment version_output service_tmp
  actual_user="$(systemctl show "${SERVICE_NAME}.service" -p User --value)"
  actual_group="$(systemctl show "${SERVICE_NAME}.service" -p Group --value)"
  actual_home="$(systemctl show "${SERVICE_NAME}.service" -p WorkingDirectory --value)"
  fragment="$(systemctl show "${SERVICE_NAME}.service" -p FragmentPath --value)"
  [ "${actual_user}" = "${SERVICE_USER}" ] && [ "${actual_group}" = "${SERVICE_GROUP}" ] \
    && [ "${actual_home}" = "${INSTALL_DIR}" ] && [ "${fragment}" = "${SERVICE_FILE}" ] \
    || die "现有服务的用户或安装路径与脚本不一致，请沿用原安装参数；未修改服务"
  prepare_install_transaction_environment
  [ ! -L "${BIN_PATH}" ] && [ -f "${BIN_PATH}" ] || die "HashCake 程序不能是符号链接或非普通文件"
  chmod 0755 -- "${BIN_PATH}" || die "无法修正 HashCake 程序权限：${BIN_PATH}"
  chown root:root -- "${BIN_PATH}" || die "无法修正 HashCake 程序属主：${BIN_PATH}"
  local binary_stat
  binary_stat="$(stat -c '权限=%a 属主=%u:%g 大小=%s' -- "${BIN_PATH}")" \
    || die "无法读取 HashCake 程序属性：${BIN_PATH}"
  if ! version_output="$(run_hashcake_as_service_user timeout 15 "${BIN_PATH}" --version 2>&1)"; then
    die "本地程序预检失败，未重启服务。原始错误：
${version_output:-请检查程序权限、CPU 架构和运行目录。}
文件属性：${binary_stat}"
  fi
  [ -n "$(extract_hashcake_version "${version_output}")" ] || die "本地程序未返回有效的 HashCake 版本号"
  service_exec_directory_matches && return 0

  # Append only the required environment setting; preserve custom unit contents.
  begin_install_transaction
  service_tmp="$(mktemp "${SERVICE_FILE}.XXXXXX.service")"
  cp -p -- "${SERVICE_FILE}" "${service_tmp}"
  printf '\n[Service]\nEnvironment="HASHCAKE_ENVELOPE_EXEC_DIR=%s"\n' "${STATE_DIR}" >> "${service_tmp}"
  if command_exists systemd-analyze && ! systemd-analyze verify "${service_tmp}"; then
    rm -f -- "${service_tmp}"
    die "服务配置校验失败，未重启服务"
  fi
  TXN_SERVICE_CHANGED=1
  mv -fT -- "${service_tmp}" "${SERVICE_FILE}"
  systemctl daemon-reload
  service_exec_directory_matches || die "启动设置被服务附加配置覆盖，无法自动修复"
  ok "已补齐本地程序所需的启动设置，原配置和服务参数保持不变"
}

show_service_start_failure() {
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  if [ -f "${LOG_DIR}/hashcake.err.log" ]; then
    printf '最近启动错误（完整日志：%s/hashcake.err.log）：\n' "${LOG_DIR}" >&2
    tail -n 60 "${LOG_DIR}/hashcake.err.log" \
      | grep -Ei '(^Error:|^Caused by:|^[[:space:]]+[0-9]+:|GLIBC_|Permission denied|thread .* panicked)' >&2 || true
  fi
}

restart_service() {
  local show_status="${1:-1}" own_transaction=0
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  if [ "${INSTALL_TRANSACTION_ACTIVE}" = "0" ]; then
    own_transaction=1
    prepare_installed_service
  fi
  if ! restart_service_checked; then
    show_service_start_failure
    die "${SERVICE_NAME}.service 启动失败或未能稳定运行"
  fi
  if [ "${own_transaction}" = "1" ] && [ "${INSTALL_TRANSACTION_ACTIVE}" = "1" ]; then
    commit_install_transaction
  fi
  if [ "${show_status}" = "1" ]; then
    status_service
  fi
}

enable_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  [ -f "${SERVICE_FILE}" ] || die "服务文件不存在，请先安装 HashCake"
  systemctl enable "${SERVICE_NAME}.service"
  systemctl is-enabled --quiet "${SERVICE_NAME}.service" \
    || die "${SERVICE_NAME}.service 未能进入 enabled 状态"
  ok "已设置开机启动"
}

disable_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  [ -f "${SERVICE_FILE}" ] || die "服务文件不存在，请先安装 HashCake"
  systemctl disable "${SERVICE_NAME}.service" \
    || die "无法关闭 ${SERVICE_NAME}.service 的开机启动"
  if systemctl is-enabled --quiet "${SERVICE_NAME}.service"; then
    die "${SERVICE_NAME}.service 仍处于 enabled 状态"
  fi
  ok "已关闭开机启动"
}

status_service() {
  if has_systemd; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  else
    pgrep -af "${BIN_PATH}" || true
  fi
  show_paths
}

log_files() {
  local path
  for path in "${LOG_DIR}/hashcake.service.log" "${LOG_DIR}/hashcake.err.log"; do
    [ -f "${path}" ] && printf '%s\n' "${path}"
  done
  shopt -s nullglob
  for path in "${LOG_DIR}"/hashcake-debug.log.*; do
    [ -f "${path}" ] && printf '%s\n' "${path}"
  done
  shopt -u nullglob
}

show_logs() {
  local lines="${LINES:-120}"
  local files
  case "${lines}" in
    ''|*[!0-9]*) die "LINES 必须是正整数：${lines}" ;;
  esac
  [ "${lines}" -gt 0 ] || die "LINES 必须大于 0"
  mapfile -t files < <(log_files)
  [ "${#files[@]}" -gt 0 ] || die "还没有日志文件：${LOG_DIR}"
  tail -n "${lines}" "${files[@]}"
}

follow_logs() {
  local files
  mapfile -t files < <(log_files)
  [ "${#files[@]}" -gt 0 ] || die "还没有日志文件：${LOG_DIR}"
  tail -F "${files[@]}"
}

clear_logs() {
  need_root
  is_installed || die "请先安装 HashCake"
  require_command find
  ensure_dirs
  find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log*' -exec sh -c ': > "$1"' _ {} \;
  ok "已清空 ${LOG_DIR} 下的日志文件"
}

edit_config() {
  need_root
  acquire_installer_lock
  is_installed || die "请先安装 HashCake"
  ensure_dirs
  install_config
  local editor="${EDITOR:-}"
  [ -n "${editor}" ] || editor="$(command -v nano || command -v vi || true)"
  [ -n "${editor}" ] || die "找不到编辑器，请设置 EDITOR"
  "${editor}" "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
  chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
}

show_paths() {
  load_install_env
  cat <<EOF

安装目录: ${INSTALL_DIR}
配置文件: ${CONFIG_FILE}
状态目录: ${STATE_DIR}
日志目录: ${LOG_DIR}
二进制:   ${BIN_PATH}
服务名:   ${SERVICE_NAME}
运行用户: ${SERVICE_USER}
管理后台: ${ADMIN_BIND:-未设置}
访问地址: $([ -n "${ADMIN_BIND:-}" ] && [ -n "${URL_PREFIX:-}" ] && admin_url || printf '未设置')
安全访问路径: $([ -n "${URL_PREFIX:-}" ] && printf '/%s/' "${URL_PREFIX}" || printf '未设置')
发布仓库: https://github.com/${RELEASE_REPO}
EOF
  if [ -s "${STATE_DIR}/metrics-token" ]; then
    printf 'Prometheus token 文件: %s\n' "${STATE_DIR}/metrics-token"
  fi
  if [ -f "${LOG_DIR}/hashcake.err.log" ] && grep -q 'bootstrap token' "${LOG_DIR}/hashcake.err.log"; then
    warn "${LOG_DIR}/hashcake.err.log 含首次令牌记录，请将该日志按敏感凭据保护"
  fi
}

change_web_settings() {
  preflight_install_or_update
  prepare_install_transaction_environment
  is_complete_install || die "HashCake 安装不完整，请先执行 install 修复或 update 更新"
  begin_install_transaction
  configure_web_defaults_for_update
  local current_port new_port new_prefix new_https
  current_port="$(bind_port "${ADMIN_BIND}")"
  if [ -t 0 ]; then
    read -r -p "Web 端口 [${current_port}]: " new_port
    read -r -p "安全访问路径 [/${URL_PREFIX}/]: " new_prefix
    read -r -p "是否启用 HTTPS，自签证书，不申请证书 [${HTTPS_ACTIVE}]: " new_https
  else
    new_port="${HASHCAKE_WEB_PORT:-}"
    new_prefix="${HASHCAKE_URL_PREFIX:-}"
    new_https="${HASHCAKE_HTTPS_ACTIVE:-}"
  fi
  if [ -n "${new_port}" ]; then
    validate_port_value "${new_port}"
    if [ "${new_port}" != "${current_port}" ] && port_in_use "${new_port}"; then
      die "Web 后台端口 ${new_port} 已被占用，请换一个端口"
    fi
    ADMIN_BIND="$(host_from_bind "${ADMIN_BIND}"):${new_port}"
  fi
  [ -n "${new_prefix}" ] && URL_PREFIX="$(normalize_url_prefix "${new_prefix}")"
  if [ -n "${new_https}" ]; then
    validate_saved_https "${new_https}"
    HTTPS_ACTIVE="${new_https}"
  fi
  write_service
  restart_service 0
  commit_install_transaction
  show_paths
}

change_limit() {
  need_root
  acquire_installer_lock
  has_systemd || die "当前系统没有可用 systemd"
  log "设置 Linux 文件句柄上限"
  grep -Fqx "${SERVICE_USER} soft nofile 1048576" /etc/security/limits.conf 2>/dev/null \
    || printf '%s\n' "${SERVICE_USER} soft nofile 1048576" >> /etc/security/limits.conf
  grep -Fqx "${SERVICE_USER} hard nofile 1048576" /etc/security/limits.conf 2>/dev/null \
    || printf '%s\n' "${SERVICE_USER} hard nofile 1048576" >> /etc/security/limits.conf
  grep -q 'DefaultLimitNOFILE=1048576' /etc/systemd/system.conf 2>/dev/null || echo 'DefaultLimitNOFILE=1048576' >> /etc/systemd/system.conf
  systemctl daemon-reexec || true
  ok "已设置 ${SERVICE_USER} 和 systemd 的文件句柄上限；服务 unit 也固定使用 1048576"
}

token_list() {
  [ -x "${BIN_PATH}" ] || die "请先安装 hashcake 二进制"
  id -u "${SERVICE_USER}" >/dev/null 2>&1 || die "服务用户不存在：${SERVICE_USER}"
  run_hashcake_as_service_user "${BIN_PATH}" --config "${CONFIG_FILE}" token list --store "${STATE_DIR}/tokens.json"
}

token_revoke() {
  local site="${1:-}"
  [ -x "${BIN_PATH}" ] || die "请先安装 hashcake 二进制"
  id -u "${SERVICE_USER}" >/dev/null 2>&1 || die "服务用户不存在：${SERVICE_USER}"
  if [ -z "${site}" ]; then
    if [ -t 0 ]; then
      read -r -p "请输入要撤销的 site_id: " site
    else
      die "site_id 不能为空；命令模式请写：$0 token-revoke <site_id>"
    fi
  fi
  [ -n "${site}" ] || die "site_id 不能为空"
  run_hashcake_as_service_user "${BIN_PATH}" --config "${CONFIG_FILE}" token revoke "${site}" --store "${STATE_DIR}/tokens.json"
  ok "已撤销 ${site}"
}

token_issue() {
  [ -x "${BIN_PATH}" ] || die "请先安装 hashcake 二进制"
  id -u "${SERVICE_USER}" >/dev/null 2>&1 || die "服务用户不存在：${SERVICE_USER}"
  local site="${TOKEN_SITE:-}"
  local backend="${TOKEN_BACKEND:-}"
  local ports_text="${TOKEN_PORTS:-}"
  local cover_text="${TOKEN_COVER_IPS:-}"
  local ttl="${TOKEN_TTL:-}"
  local miner_bind="${TOKEN_MINER_BIND:-0.0.0.0}"
  local single_cover="${TOKEN_SINGLE_COVER:-}"

  if [ -z "${site}" ] && [ -t 0 ]; then
    read -r -p "site_id，例如 site-shenzhen-01: " site
  fi
  [ -n "${site}" ] || die "site_id 不能为空；命令模式请设置 TOKEN_SITE"

  if [ -z "${backend}" ] && [ -t 0 ]; then
    read -r -p "Backend 地址，例如 your-hashcake.example:18446: " backend
  fi
  [ -n "${backend}" ] || die "Backend 地址不能为空；命令模式请设置 TOKEN_BACKEND"

  if [ -z "${ports_text}" ] && [ -t 0 ]; then
    read -r -p "开放给该 CakeBox 的端口，多个用逗号分隔，留空=配置内全部端口: " ports_text
  fi

  if [ -z "${cover_text}" ] && [ -t 0 ]; then
    read -r -p "cover IP，多个用逗号分隔；单 IP 部署只填一个: " cover_text
  fi
  [ -n "${cover_text}" ] || die "cover IP 不能为空；命令模式请设置 TOKEN_COVER_IPS"

  if [ -z "${ttl}" ] && [ -t 0 ]; then
    read -r -p "有效期秒数，留空=永久: " ttl
  fi
  if [ -z "${single_cover}" ] && [ "$(count_csv_items "${cover_text}")" = "1" ]; then
    single_cover="1"
  fi

  local args=(--config "${CONFIG_FILE}" token issue --site "${site}" --backend "${backend}" --store "${STATE_DIR}/tokens.json" --miner-bind "${miner_bind}")
  local item
  IFS=',' read -r -a port_items <<< "${ports_text}"
  for item in "${port_items[@]}"; do
    item="$(trim_whitespace "${item}")"
    [ -n "${item}" ] && args+=(--port "${item}")
  done
  IFS=',' read -r -a cover_items <<< "${cover_text}"
  for item in "${cover_items[@]}"; do
    item="$(trim_whitespace "${item}")"
    [ -n "${item}" ] && args+=(--cover-ip "${item}")
  done
  [ -n "${ttl}" ] && args+=(--ttl "${ttl}")
  [ "${single_cover}" = "1" ] && args+=(--single-cover)

  run_hashcake_as_service_user "${BIN_PATH}" "${args[@]}"
}

uninstall() {
  need_root
  reject_space_path
  validate_runtime_inputs
  validate_safe_absolute_path "${INSTALL_DIR}" "安装目录"
  acquire_installer_lock
  local confirm="${CONFIRM_UNINSTALL:-}"
  if [ "${confirm}" != "yes" ]; then
    if [ -t 0 ]; then
      read -r -p "确认卸载并删除 ${INSTALL_DIR}？输入 yes 继续: " confirm
    else
      die "非交互卸载需要设置 CONFIRM_UNINSTALL=yes"
    fi
  fi
  [ "${confirm}" = "yes" ] || die "已取消卸载"
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "${INSTALL_DIR}"
  ok "已卸载 ${APP_NAME}"
}


# ── Web 后台账号密码 ────────────────────────────────────────────────────
#
# 后台账号（owner/admin）存在 ${STATE_DIR}/admin.json 里，密码只以 Argon2id 的
# PHC 串落盘，脚本不重复实现这套哈希，而是走 daemon 自己已发布的 HTTP 接口：
#
#   改密：POST /api/v1/admin/login 换会话令牌 → PATCH /api/v1/admin/accounts/{id}
#   找回：清空 accounts 后重启，daemon 会重新打印一次性 bootstrap 令牌，再用它
#         POST /api/v1/admin/accounts 重建首个 Owner（这正是 daemon 的既有语义：
#         账号表为空且没有可用 setup 凭据时重新武装首启令牌，避免永久锁死）。
#
# 两条路径都只依赖接口契约，不需要重新编译或重新下载二进制。

admin_api_base_url() {
  local scheme="http" host port
  case "${HTTPS_ACTIVE:-}" in true|1|yes|on) scheme="https" ;; esac
  host="$(host_from_bind "${ADMIN_BIND}")"
  port="$(bind_port "${ADMIN_BIND}")"
  case "${host}" in
    0.0.0.0|"") host="127.0.0.1" ;;
    ::|\[::\]) host="[::1]" ;;
    *) host="$(format_url_host "${host}")" ;;
  esac
  printf '%s://%s:%s' "${scheme}" "${host}" "${port}"
}

# install.env 里的 HTTPS 只是安装当时的快照；Web 后台改过之后，只有 admin.json
# 是 daemon 真正读取的权威值。这里以 admin.json 为准，避免用 http 去打 TLS 端口。
load_admin_api_settings() {
  load_install_env
  [ -n "${ADMIN_BIND:-}" ] || die "未找到 Web 后台监听地址，请先执行 install 或 web-settings"
  local https_value=""
  https_value="$(python3 - "${STATE_DIR}/admin.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if os.path.islink(path) or not os.path.isfile(path):
    raise SystemExit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(0)
security = data.get("security")
if isinstance(security, dict) and isinstance(security.get("https_active"), bool):
    print("true" if security["https_active"] else "false")
PY
)"
  [ -z "${https_value}" ] || HTTPS_ACTIVE="${https_value}"
  ADMIN_API_BASE="$(admin_api_base_url)"
}

validate_admin_username() {
  local name="$1"
  [ -n "${name}" ] || die "账号不能为空"
  case "${name}" in
    *[!A-Za-z0-9_.-]*) die "账号只能包含字母、数字、下划线、短横线和点：${name}" ;;
  esac
  if [ "${#name}" -lt 3 ] || [ "${#name}" -gt 32 ]; then
    die "账号长度必须是 3-32 个字符：${name}"
  fi
}

# 与服务端 policy 对齐（8-128 个字符）。常见弱口令黑名单交给服务端返回，
# 避免同一条清单在脚本和 Rust 里各存一份、各自漂移。
validate_admin_password() {
  local password="$1" label="${2:-密码}"
  case "${password}" in
    *$'\n'*|*$'\r'*) die "${label}不能包含换行符" ;;
  esac
  if [ "${#password}" -lt 8 ] || [ "${#password}" -gt 128 ]; then
    die "${label}长度必须是 8-128 个字符"
  fi
}

# 读取 admin.json 的账号清单，每行输出 "id<TAB>用户名<TAB>角色"。
admin_account_list() {
  python3 - "${STATE_DIR}/admin.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if os.path.islink(path) or not os.path.isfile(path):
    raise SystemExit(f"后台状态文件不存在：{path}")
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    raise SystemExit(f"后台状态文件无法解析：{exc}")
accounts = data.get("accounts")
if accounts is None:
    accounts = []
if not isinstance(accounts, list):
    raise SystemExit("后台状态文件的 accounts 字段不是数组")
for account in accounts:
    if not isinstance(account, dict):
        continue
    account_id = account.get("id")
    username = account.get("username")
    role = account.get("role")
    if not isinstance(account_id, str) or not isinstance(username, str):
        continue
    print("\t".join((account_id, username, role if isinstance(role, str) else "unknown")))
PY
}

admin_role_label() {
  case "$1" in
    owner) printf 'Owner（所有者）' ;;
    admin) printf 'Admin（管理员）' ;;
    *) printf '%s' "$1" ;;
  esac
}

# 调用后台 HTTP 接口：$1=方法 $2=路径 $3=Bearer 令牌（可空）$4=JSON 请求体（可空）。
# 成功时把响应体写到 stdout；失败时退出码 3=认证被拒 / 4=其它 HTTP 错误 / 5=连不上。
# 令牌与请求体只经文件描述符传递，不进 argv，避免在 ps 里暴露。
admin_api_call() {
  local method="$1" path="$2" token="$3" body="$4"
  python3 - "${ADMIN_API_BASE}" "${method}" "${path}" 3<<<"${token}" 4<<<"${body}" <<'PY'
import json
import ssl
import sys
import urllib.error
import urllib.request

base, method, path = sys.argv[1:4]
with open(3, "r", encoding="utf-8", closefd=False) as token_fd:
    token = token_fd.read().strip()
with open(4, "r", encoding="utf-8", closefd=False) as body_fd:
    body = body_fd.read().strip()

headers = {"Accept": "application/json"}
data = None
if body:
    data = body.encode("utf-8")
    headers["Content-Type"] = "application/json"
if token:
    headers["Authorization"] = f"Bearer {token}"

handlers = [urllib.request.ProxyHandler({})]
if base.startswith("https://"):
    # 自签证书是官方支持的部署方式；这里只连回环地址，不做证书校验。
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    handlers.append(urllib.request.HTTPSHandler(context=context))
opener = urllib.request.build_opener(*handlers)
request = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
try:
    with opener.open(request, timeout=15) as response:
        sys.stdout.write(response.read().decode("utf-8", "replace"))
except urllib.error.HTTPError as exc:
    payload = exc.read().decode("utf-8", "replace")
    detail = ""
    try:
        parsed = json.loads(payload)
    except ValueError:
        parsed = None
    if isinstance(parsed, dict):
        for key in ("detail", "title"):
            value = parsed.get(key)
            if isinstance(value, str) and value.strip():
                detail = value.strip()
                break
    if not detail:
        detail = payload.strip()[:200]
    print(f"HTTP {exc.code}" + (f"：{detail}" if detail else ""), file=sys.stderr)
    raise SystemExit(3 if exc.code in (401, 403) else 4)
except (urllib.error.URLError, TimeoutError, OSError) as exc:
    print(f"无法连接后台接口：{exc}", file=sys.stderr)
    raise SystemExit(5)
PY
}

admin_json_login_body() {
  local username="$1" password="$2"
  python3 - "${username}" 3<<<"${password}" <<'PY'
import json
import sys

with open(3, "r", encoding="utf-8", closefd=False) as fh:
    password = fh.read().rstrip("\n")
sys.stdout.write(json.dumps({"username": sys.argv[1], "password": password}))
PY
}

admin_json_password_body() {
  local password="$1"
  python3 - 3<<<"${password}" <<'PY'
import json
import sys

with open(3, "r", encoding="utf-8", closefd=False) as fh:
    password = fh.read().rstrip("\n")
sys.stdout.write(json.dumps({"password": password}))
PY
}

admin_json_create_body() {
  local username="$1" password="$2"
  python3 - "${username}" 3<<<"${password}" <<'PY'
import json
import sys

with open(3, "r", encoding="utf-8", closefd=False) as fh:
    password = fh.read().rstrip("\n")
sys.stdout.write(json.dumps({"username": sys.argv[1], "password": password, "role": "owner"}))
PY
}

# 登录并输出 "会话令牌<TAB>账号id<TAB>用户名<TAB>角色"。失败即 die。
admin_api_login() {
  local username="$1" password="$2" body="" response="" status=0 parsed=""
  local session="" account_id="" account_user="" account_role=""
  body="$(admin_json_login_body "${username}" "${password}")" || die "无法构造登录请求"
  response="$(admin_api_call POST /api/v1/admin/login "" "${body}")" || status=$?
  case "${status}" in
    0) ;;
    3) die "登录被拒绝：账号或密码不正确" ;;
    5) die "无法连接后台接口 ${ADMIN_API_BASE}；请确认 ${SERVICE_NAME}.service 正在运行" ;;
    *) die "后台接口调用失败（退出码 ${status}）" ;;
  esac
  parsed="$(python3 - 3<<<"${response}" <<'PY'
import json
import sys

with open(3, "r", encoding="utf-8", closefd=False) as fh:
    payload = fh.read()
try:
    data = json.loads(payload)
except ValueError:
    raise SystemExit("后台登录响应不是合法 JSON")
token = data.get("token")
account = data.get("account")
if not isinstance(token, str) or not token.strip():
    raise SystemExit("后台登录响应缺少会话令牌")
if not isinstance(account, dict):
    account = {}
print("\t".join((
    token.strip(),
    str(account.get("id", "")),
    str(account.get("username", "")),
    str(account.get("role", "")),
)))
PY
)" || die "无法解析后台登录响应"
  IFS=$'\t' read -r session account_id account_user account_role <<< "${parsed}"
  [ -n "${session}" ] || die "后台登录响应缺少会话令牌"
  printf '%s\t%s\t%s\t%s' "${session}" "${account_id}" "${account_user}" "${account_role}"
}

# 清空 accounts，并移除 setup / legacy_admin 令牌，让 daemon 下次启动重新武装
# 一次性 bootstrap 令牌。写回沿用 daemon 自己的属主与 0600 权限。
admin_clear_accounts() {
  run_as_service_user python3 - "${STATE_DIR}/admin.json" <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]
if not os.path.lexists(path):
    # 没有状态文件时无需清空：daemon 下次启动本来就会重新武装一次性 bootstrap 令牌。
    print("removed_accounts=0 removed_tokens=0")
    raise SystemExit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    raise SystemExit(f"后台状态文件无法解析：{exc}")
if not isinstance(data, dict):
    raise SystemExit("后台状态文件根节点不是对象")
accounts = data.get("accounts")
if accounts is None:
    accounts = []
if not isinstance(accounts, list):
    raise SystemExit("后台状态文件的 accounts 字段不是数组")
removed_accounts = len(accounts)
data["accounts"] = []
removed_tokens = 0
tokens = data.get("tokens")
if isinstance(tokens, list):
    kept = []
    for token in tokens:
        if isinstance(token, dict) and token.get("kind") in ("setup", "legacy_admin"):
            removed_tokens += 1
            continue
        kept.append(token)
    data["tokens"] = kept
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix=".admin.json.reset.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(f"removed_accounts={removed_accounts} removed_tokens={removed_tokens}")
PY
}

# 修改现有账号的密码（需要当前密码）。非交互模式读 HASHCAKE_ADMIN_* 环境变量。
admin_change_password() {
  local accounts_text="" target_id="" target_user="" target_role="" login_user="" login_input=""
  local current_password="" new_password="" confirm_password="" body="" status=0 login_result=""
  local session="" login_id="" login_role="" choice="" index=0
  local account_id="" account_user="" account_role=""
  local -a account_ids=() account_users=() account_roles=()

  systemctl is-active --quiet "${SERVICE_NAME}.service" \
    || die "${SERVICE_NAME}.service 未运行；请先执行 $0 start（忘记密码请选择「重置后台账号」）"
  accounts_text="$(admin_account_list)" || die "无法读取后台账号清单"
  [ -n "${accounts_text}" ] || die "后台还没有账号；请先用首次 Web访问令牌在网页激活，或选择「重置后台账号」"
  while IFS=$'\t' read -r account_id account_user account_role; do
    [ -n "${account_id:-}" ] || continue
    account_ids+=("${account_id}")
    account_users+=("${account_user}")
    account_roles+=("${account_role:-unknown}")
  done <<< "${accounts_text}"

  if [ -n "${HASHCAKE_ADMIN_USER:-}" ]; then
    target_user="${HASHCAKE_ADMIN_USER}"
  elif [ "${#account_ids[@]}" -eq 1 ]; then
    target_user="${account_users[0]}"
  elif [ -t 0 ]; then
    printf '\n现有后台账号：\n'
    for index in "${!account_ids[@]}"; do
      printf '  %d) %s（%s）\n' "$((index + 1))" "${account_users[index]}" "$(admin_role_label "${account_roles[index]}")"
    done
    read -r -p "要修改哪个账号的密码 [1-${#account_ids[@]}]（默认 1）: " choice
    choice="${choice:-1}"
    case "${choice}" in
      *[!0-9]*) die "请输入账号序号：${choice}" ;;
    esac
    [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#account_ids[@]}" ] || die "账号序号超出范围：${choice}"
    target_user="${account_users[$((choice - 1))]}"
  else
    die "存在多个后台账号；非交互模式请用 HASHCAKE_ADMIN_USER 指定要修改的账号"
  fi
  for index in "${!account_users[@]}"; do
    if [ "${account_users[index]}" = "${target_user}" ]; then
      target_id="${account_ids[index]}"
      target_role="${account_roles[index]}"
      break
    fi
  done
  [ -n "${target_id}" ] || die "后台账号不存在：${target_user}"

  login_user="${HASHCAKE_ADMIN_LOGIN_USER:-${target_user}}"
  if [ -t 0 ]; then
    read -r -p "用于验证身份的账号 [${login_user}]: " login_input
    [ -z "${login_input}" ] || login_user="${login_input}"
    read -r -s -p "当前密码: " current_password
    printf '\n'
    read -r -s -p "新密码（8-128 个字符）: " new_password
    printf '\n'
    read -r -s -p "再次输入新密码: " confirm_password
    printf '\n'
  else
    current_password="${HASHCAKE_ADMIN_CURRENT_PASSWORD:-}"
    new_password="${HASHCAKE_ADMIN_NEW_PASSWORD:-}"
    confirm_password="${new_password}"
  fi
  [ -n "${current_password}" ] || die "当前密码不能为空"
  [ -n "${new_password}" ] || die "新密码不能为空"
  validate_admin_password "${new_password}" "新密码"
  [ "${new_password}" = "${confirm_password}" ] || die "两次输入的新密码不一致"
  [ "${new_password}" != "${current_password}" ] || die "新密码不能与当前密码相同"

  log "校验 ${login_user} 的身份"
  login_result="$(admin_api_login "${login_user}" "${current_password}")"
  IFS=$'\t' read -r session login_id login_role _ <<< "${login_result}"
  if [ "${login_id}" != "${target_id}" ] && [ "${login_role}" != "owner" ]; then
    die "账号 ${login_user} 不是 Owner，只能修改自己的密码"
  fi

  body="$(admin_json_password_body "${new_password}")" || die "无法构造改密请求"
  status=0
  admin_api_call PATCH "/api/v1/admin/accounts/${target_id}" "${session}" "${body}" >/dev/null || status=$?
  case "${status}" in
    0) ;;
    3) die "改密被拒绝：当前账号没有权限，或会话已失效" ;;
    5) die "无法连接后台接口 ${ADMIN_API_BASE}" ;;
    *) die "改密失败（退出码 ${status}）" ;;
  esac
  admin_api_login "${target_user}" "${new_password}" >/dev/null
  ok "已修改后台账号 ${target_user}（${target_role:-unknown}）的密码；该账号的其它登录会话已被吊销"
}

# 重置失败时把备份还原回去并重新拉起服务。回滚本身失败只警告，不掩盖原始错误。
admin_restore_admin_store() {
  local backup_path="$1"
  [ -n "${backup_path}" ] || return 0
  # 先停服务再还原：运行中的 daemon 仍持有「账号已清空」的内存状态，之后任何一次会话写入
  # 都可能把刚还原的文件覆盖掉。停掉 → 还原 → 拉起，落盘的一定是备份内容。
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  cp -a -- "${backup_path}" "${STATE_DIR}/admin.json" \
    || warn "回滚 ${STATE_DIR}/admin.json 失败，请手工恢复备份 ${backup_path}"
  restart_service_checked \
    || warn "回滚后 ${SERVICE_NAME}.service 未能重新启动，请手工检查"
}

# 忘记密码时的恢复路径：清空后台账号表 → 重启 → 用 daemon 重新打印的一次性
# bootstrap 令牌重建首个 Owner。会删除现有账号（含其它账号），因此先备份、失败即回滚。
admin_reset_password() {
  local accounts_text="" confirm="" backup_path="" start_line=1 token="" body="" status=0
  local username="" password="" confirm_password="" index=0
  local account_id="" account_user="" account_role=""
  local -a account_users=() account_roles=()

  has_systemd || die "当前系统没有可用 systemd"
  accounts_text="$(admin_account_list 2>/dev/null || true)"
  printf '\n即将重建后台管理员账号。\n'
  if [ -n "${accounts_text}" ]; then
    while IFS=$'\t' read -r account_id account_user account_role; do
      [ -n "${account_id:-}" ] || continue
      account_users+=("${account_user}")
      account_roles+=("${account_role:-unknown}")
    done <<< "${accounts_text}"
    printf '现有账号（重建后都会消失）：\n'
    for index in "${!account_users[@]}"; do
      printf '  - %s（%s）\n' "${account_users[index]}" "$(admin_role_label "${account_roles[index]}")"
    done
  else
    printf '当前没有可用的后台账号。\n'
  fi
  warn "重建后只有新账号能登录，原账号、原密码与旧会话全部失效"
  if [ -t 0 ]; then
    read -r -p "输入 RESET 确认重建: " confirm
  else
    confirm="${HASHCAKE_ADMIN_RESET_CONFIRM:-}"
  fi
  [ "${confirm}" = "RESET" ] || die "已取消（需要输入 RESET）"

  if [ -t 0 ]; then
    read -r -p "新账号 [admin]: " username
    username="${username:-admin}"
    read -r -s -p "新密码（8-128 个字符）: " password
    printf '\n'
    read -r -s -p "再次输入新密码: " confirm_password
    printf '\n'
  else
    username="${HASHCAKE_ADMIN_USER:-admin}"
    password="${HASHCAKE_ADMIN_NEW_PASSWORD:-}"
    confirm_password="${password}"
  fi
  validate_admin_username "${username}"
  validate_admin_password "${password}" "新密码"
  [ "${password}" = "${confirm_password}" ] || die "两次输入的新密码不一致"

  prepare_installed_service
  ensure_installer_state_dir
  # 备份放在停服务之前：拷贝失败时服务仍在运行，不会把矿场留在一个「已停且没改成」的状态。
  backup_path=""
  if [ -e "${STATE_DIR}/admin.json" ] || [ -L "${STATE_DIR}/admin.json" ]; then
    backup_path="${INSTALLER_STATE_DIR}/admin.json.reset.$(date +%Y%m%d%H%M%S)"
    cp -a -- "${STATE_DIR}/admin.json" "${backup_path}" || die "备份 ${STATE_DIR}/admin.json 失败，未做任何修改"
    chmod 600 -- "${backup_path}"
    log "已备份后台状态到 ${backup_path}"
  fi
  stop_service
  if ! admin_clear_accounts >/dev/null; then
    warn "清空后台账号失败，正在回滚"
    admin_restore_admin_store "${backup_path}"
    die "清空后台账号失败，已回滚到原状态"
  fi
  if [ -f "${LOG_DIR}/hashcake.err.log" ]; then
    start_line=$(( $(wc -l < "${LOG_DIR}/hashcake.err.log") + 1 ))
  fi
  if ! restart_service_checked; then
    show_service_start_failure
    admin_restore_admin_store "${backup_path}"
    die "${SERVICE_NAME}.service 重建后启动失败，已回滚到原状态"
  fi
  token="$(wait_for_bootstrap_token "${start_line}" || true)"
  if [ -z "${token}" ]; then
    admin_restore_admin_store "${backup_path}"
    die "未能从启动日志提取新的首次 Web访问令牌，已回滚到原状态"
  fi
  body="$(admin_json_create_body "${username}" "${password}")" || die "无法构造建号请求"
  status=0
  admin_api_call POST /api/v1/admin/accounts "${token}" "${body}" >/dev/null || status=$?
  case "${status}" in
    0) ;;
    3)
      admin_restore_admin_store "${backup_path}"
      die "首次 Web访问令牌被拒绝（可能已过期）；已回滚到原状态，请重试"
      ;;
    *)
      admin_restore_admin_store "${backup_path}"
      die "创建后台账号失败（退出码 ${status}）；已回滚到原状态"
      ;;
  esac
  admin_api_login "${username}" "${password}" >/dev/null
  ok "已重建后台账号 ${username}（Owner）"
  printf '\n后台访问地址: %s\n' "$(admin_url)"
  if [ -n "${backup_path}" ]; then
    printf '后台状态备份: %s\n' "${backup_path}"
    printf '提示: 确认新账号可以登录后，可自行删除该备份文件\n'
  fi
}

# 菜单 15 / CLI admin-password 的统一入口。
admin_password() {
  preflight_install_or_update
  is_complete_install || die "HashCake 安装不完整，请先执行 install 修复或 update 更新"
  load_admin_api_settings
  if [ "${HASHCAKE_ADMIN_RESET:-}" = "1" ]; then
    admin_reset_password
    return 0
  fi
  local mode="1"
  if [ -t 0 ]; then
    cat <<'EOF'

1. 修改账号密码（需要当前密码）
2. 重置后台账号（忘记密码；删除现有账号并重建 Owner）
0. 返回
EOF
    read -r -p "请选择 [0-2]: " mode
  fi
  case "${mode}" in
    1) admin_change_password ;;
    2) admin_reset_password ;;
    0|"") return 0 ;;
    *) die "无效选择" ;;
  esac
}
menu() {
  clear || true
  cat <<EOF
========== ${APP_NAME} 一键安装管理 ==========
安装目录: ${INSTALL_DIR}
服务名:   ${SERVICE_NAME}

1. 首次安装
2. 更新程序
3. 启动
4. 停止
5. 重启
6. 查看运行状态
7. 查看最近日志
8. 实时跟随日志
9. 清空日志
10. 设置开机启动
11. 关闭开机启动
12. 编辑配置
13. 查看路径和访问地址
14. 修改 Web 访问设置
15. 修改后台账号密码
16. 签发隧道加密令牌
17. 查看隧道加密令牌列表
18. 撤销隧道加密令牌
19. 关闭并禁用整机防火墙
20. 解除系统连接数限制
21. 卸载
0. 退出
EOF
  read -r -p "请选择 [0-21]: " choice
  case "${choice}" in
    1) install_service ;;
    2) update_service ;;
    3) start_service ;;
    4) stop_service ;;
    5) restart_service ;;
    6) status_service ;;
    7) show_logs ;;
    8) follow_logs ;;
    9) clear_logs ;;
    10) enable_service ;;
    11) disable_service ;;
    12) edit_config ;;
    13) show_paths ;;
    14) change_web_settings ;;
    15) admin_password ;;
    16) token_issue ;;
    17) token_list ;;
    18) token_revoke ;;
    19) disable_firewall ;;
    20) change_limit ;;
    21) uninstall ;;
    0) exit 0 ;;
    *) die "无效选择" ;;
  esac
}

resolve_installer_command() {
  if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
    printf 'menu'
  else
    printf '%s' "$1"
  fi
}

if [ "${HASHCAKE_INSTALLER_SOURCE_ONLY:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

require_bash_runtime
cmd="$(resolve_installer_command "$@")"
case "${cmd}" in
  install) install_service ;;
  update) update_service ;;
  start) start_service ;;
  stop) stop_service ;;
  restart) restart_service ;;
  status) status_service ;;
  logs) show_logs ;;
  follow-logs) follow_logs ;;
  clear-logs) clear_logs ;;
  enable) enable_service ;;
  disable) disable_service ;;
  edit-config) edit_config ;;
  paths|show-url) show_paths ;;
  web-settings|configure-web) change_web_settings ;;
  admin-password|set-password) admin_password ;;
  admin-reset|reset-password) HASHCAKE_ADMIN_RESET=1 admin_password ;;
  disable-firewall) disable_firewall ;;
  limit) change_limit ;;
  token-issue|token-create) shift; token_issue "$@" ;;
  token-list) token_list ;;
  token-revoke) shift; token_revoke "$@" ;;
  write-service)
    preflight_install_or_update
    prepare_install_transaction_environment
    is_installed || die "请先安装 HashCake"
    begin_install_transaction
    configure_web_defaults_for_update
    ensure_metrics_token
    install_config
    write_service
    commit_install_transaction
    ;;
  uninstall) uninstall ;;
  menu|"") menu ;;
  *) die "未知命令：${cmd}" ;;
esac
