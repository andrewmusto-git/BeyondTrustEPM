#!/usr/bin/env python3
"""
BeyondTrust EPM (Privilege Management Cloud) to Veza OAA Integration Script.

Collects identity and permission data from BeyondTrust PM Cloud and pushes
to Veza's Open Authorization API (OAA) as a CustomApplication.

Entity model:
  - BeyondTrust Users        → OAA Local Users
  - BeyondTrust Roles        → OAA Local Roles
  - BeyondTrust GlobalRoles  → OAA Local Roles (global/system-wide)
  - BeyondTrust Policies     → OAA Application Resources
  - Role allowPermissions    → OAA Custom Permissions

Authentication:
  BeyondTrust PM Cloud uses OAuth2 Client Credentials.
  Token endpoint: https://<tenant>.pm.beyondtrustcloud.com/oauth/connect/token
  Scope: urn:management:api

API Version: v3 (management-api/v3)
  Rate limit: 1000 requests per 100 seconds
"""

import argparse
import logging
import os
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler
from typing import Dict, List, Optional, Union

import requests
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission, OAAPropertyType

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

log = logging.getLogger(__name__)


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure console + file logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    fmt = logging.Formatter(
        fmt="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    file_handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    file_handler.setFormatter(fmt)

    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setFormatter(fmt)

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(file_handler)
    root.addHandler(console_handler)


# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="BeyondTrust EPM → Veza OAA integration",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Source — BeyondTrust PM Cloud
    src = parser.add_argument_group("BeyondTrust PM Cloud source")
    src.add_argument(
        "--bt-url",
        default=None,
        help="BeyondTrust PM Cloud base URL  (env: BT_URL)",
    )
    src.add_argument(
        "--bt-client-id",
        default=None,
        help="OAuth2 client ID               (env: BT_CLIENT_ID)",
    )
    src.add_argument(
        "--bt-client-secret",
        default=None,
        help="OAuth2 client secret           (env: BT_CLIENT_SECRET)",
    )

    # Veza
    veza = parser.add_argument_group("Veza")
    veza.add_argument("--veza-url", default=None, help="Veza tenant URL (env: VEZA_URL)")
    veza.add_argument(
        "--veza-api-key", default=None, help="Veza API key (env: VEZA_API_KEY)"
    )

    # OAA provider / datasource
    oaa = parser.add_argument_group("OAA provider")
    oaa.add_argument(
        "--provider-name",
        default="BeyondTrust EPM",
        help="Provider name shown in Veza",
    )
    oaa.add_argument(
        "--datasource-name",
        default="BeyondTrust PM Cloud",
        help="Datasource name shown in Veza",
    )

    # Operational
    ops = parser.add_argument_group("Operational")
    ops.add_argument(
        "--env-file",
        default=".env",
        help="Path to .env file with credentials",
    )
    ops.add_argument(
        "--dry-run",
        action="store_true",
        help="Build the OAA payload but do NOT push to Veza",
    )
    ops.add_argument(
        "--save-json",
        action="store_true",
        help="Save the OAA JSON payload to disk for inspection",
    )
    ops.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity",
    )
    ops.add_argument(
        "--page-size",
        type=int,
        default=200,
        help="Number of records per API page (max 200)",
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Configuration — CLI → env var → .env file precedence
# ---------------------------------------------------------------------------

def load_config(args: argparse.Namespace) -> dict:
    """Resolve credentials: CLI arg > env var > .env file."""
    env_path = getattr(args, "env_file", ".env")
    if env_path and os.path.exists(env_path):
        load_dotenv(env_path)
        log.debug("Loaded .env from %s", env_path)

    config = {
        "bt_url": (args.bt_url or os.getenv("BT_URL", "")).rstrip("/"),
        "bt_client_id": args.bt_client_id or os.getenv("BT_CLIENT_ID", ""),
        "bt_client_secret": args.bt_client_secret or os.getenv("BT_CLIENT_SECRET", ""),
        "veza_url": args.veza_url or os.getenv("VEZA_URL", ""),
        "veza_api_key": args.veza_api_key or os.getenv("VEZA_API_KEY", ""),
    }
    return config


def validate_config(config: dict, dry_run: bool) -> None:
    """Abort early if required credentials are missing."""
    required = ["bt_url", "bt_client_id", "bt_client_secret"]
    if not dry_run:
        required += ["veza_url", "veza_api_key"]
    missing = [k for k in required if not config.get(k)]
    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        sys.exit(1)


# ---------------------------------------------------------------------------
# BeyondTrust PM Cloud API client
# ---------------------------------------------------------------------------

class BeyondTrustClient:
    """Thin REST client for BeyondTrust PM Cloud Management API v3."""

    TOKEN_PATH = "/oauth/connect/token"
    API_PREFIX = "/management-api/v3"
    SCOPE = "urn:management:api"

    def __init__(self, base_url: str, client_id: str, client_secret: str, page_size: int = 200):
        self._base_url = base_url.rstrip("/")
        self._client_id = client_id
        self._client_secret = client_secret
        self._page_size = page_size
        self._session = requests.Session()
        self._session.headers["Accept"] = "application/json"
        self._token: str = ""

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    def authenticate(self) -> None:
        """Obtain an OAuth2 Bearer token using client credentials flow."""
        token_url = f"{self._base_url}{self.TOKEN_PATH}"
        log.info("Requesting OAuth2 token from %s", token_url)
        resp = self._session.post(
            token_url,
            data={
                "grant_type": "client_credentials",
                "client_id": self._client_id,
                "client_secret": self._client_secret,
                "scope": self.SCOPE,
            },
            timeout=30,
        )
        if resp.status_code != 200:
            log.error(
                "OAuth2 token request failed: HTTP %s — %s",
                resp.status_code,
                resp.text[:500],
            )
            sys.exit(1)
        data = resp.json()
        self._token = data.get("access_token", "")
        if not self._token:
            log.error("OAuth2 response did not contain access_token: %s", data)
            sys.exit(1)
        self._session.headers["Authorization"] = f"Bearer {self._token}"
        log.info("BeyondTrust authentication successful")

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _get(self, path: str, params: Optional[dict] = None) -> Union[dict, list]:
        url = f"{self._base_url}{self.API_PREFIX}{path}"
        resp = self._session.get(url, params=params, timeout=30)
        if resp.status_code == 401:
            log.error(
                "HTTP 401 Unauthorized fetching %s — "
                "verify the API client in BeyondTrust has 'Users API' access granted.\n"
                "Response body: %s",
                url,
                resp.text[:1000],
            )
            sys.exit(1)
        resp.raise_for_status()
        return resp.json()

    def _paginate(self, path: str, extra_params: Optional[dict] = None) -> list:
        """Iterate through paginated endpoint, returning all records."""
        records = []
        page = 1
        while True:
            params = {
                "Pagination.PageSize": self._page_size,
                "Pagination.PageNumber": page,
            }
            if extra_params:
                params.update(extra_params)
            data = self._get(path, params=params)
            items = data.get("data") or []
            records.extend(items)
            log.debug(
                "%s page %d: got %d records (total so far: %d)",
                path,
                page,
                len(items),
                len(records),
            )
            total = data.get("totalRecordCount", 0)
            if len(records) >= total or not items:
                break
            page += 1
        return records

    # ------------------------------------------------------------------
    # Data collection
    # ------------------------------------------------------------------

    def get_users(self) -> list:
        log.info("Fetching users …")
        users = self._paginate("/Users")
        log.info("Fetched %d users", len(users))
        return users

    def get_roles(self) -> list:
        log.info("Fetching roles …")
        roles = self._get("/Roles")
        if isinstance(roles, list):
            log.info("Fetched %d roles", len(roles))
            return roles
        # Defensive: some versions may return a paged response
        items = roles.get("data", roles)
        log.info("Fetched %d roles", len(items))
        return items

    def get_groups(self) -> list:
        log.info("Fetching computer groups …")
        groups = self._paginate("/Groups")
        log.info("Fetched %d groups", len(groups))
        return groups

    def get_policies(self) -> list:
        log.info("Fetching policies …")
        policies = self._paginate("/Policies")
        log.info("Fetched %d policies", len(policies))
        return policies

    def get_global_roles(self) -> list:
        """Fetch global/system-wide roles (new in API v3)."""
        log.info("Fetching global roles …")
        global_roles = self._paginate("/GlobalRoles")
        log.info("Fetched %d global roles", len(global_roles))
        return global_roles


# ---------------------------------------------------------------------------
# OAA payload builder
# ---------------------------------------------------------------------------

# Map BeyondTrust permission action strings → Veza OAA permission types.
# Keys are lower-cased substrings of the action field.
_ACTION_TO_OAA: Dict[str, List[OAAPermission]] = {
    "read":          [OAAPermission.DataRead, OAAPermission.MetadataRead],
    "view":          [OAAPermission.DataRead, OAAPermission.MetadataRead],
    "list":          [OAAPermission.DataRead, OAAPermission.MetadataRead],
    "create":        [OAAPermission.DataWrite, OAAPermission.MetadataWrite],
    "write":         [OAAPermission.DataRead, OAAPermission.DataWrite,
                      OAAPermission.MetadataRead],
    "update":        [OAAPermission.DataRead, OAAPermission.DataWrite,
                      OAAPermission.MetadataRead],
    "modify":        [OAAPermission.DataRead, OAAPermission.DataWrite,
                      OAAPermission.MetadataRead],
    "delete":        [OAAPermission.DataWrite, OAAPermission.MetadataWrite],
    "manage":        [OAAPermission.DataRead, OAAPermission.DataWrite,
                      OAAPermission.MetadataRead, OAAPermission.MetadataWrite],
    "admin":         [OAAPermission.DataRead, OAAPermission.DataWrite,
                      OAAPermission.MetadataRead, OAAPermission.MetadataWrite,
                      OAAPermission.NonData],
    "full":          [OAAPermission.DataRead, OAAPermission.DataWrite,
                      OAAPermission.MetadataRead, OAAPermission.MetadataWrite,
                      OAAPermission.NonData],
}

_DEFAULT_OAA_PERMS = [OAAPermission.DataRead, OAAPermission.MetadataRead]


def _infer_fallback_permission(role_name: str) -> str:
    """Return a registered fallback permission key (read/write/admin) inferred from role name.

    Used when a role's allowPermissions list is empty — common for BeyondTrust built-in
    management roles that do not expose their permission definitions via the API.
    """
    name_lower = role_name.lower()
    if "admin" in name_lower:
        return "admin"
    if any(kw in name_lower for kw in ("creator", "write", "update", "modify", "editor")):
        return "write"
    return "read"


def _effective_permission_key(perm_names: List[str], role_name: str = "") -> str:
    """Return the highest effective permission key (admin/write/read) from a role's permission list.

    Checks the permission names assigned to the role; falls back to role-name inference
    if the list is empty or does not match any known keyword.
    """
    combined = " ".join(p.lower() for p in perm_names)
    if "admin" in combined or "full" in combined:
        return "admin"
    if any(kw in combined for kw in ("write", "manage", "update", "modify", "create", "delete")):
        return "write"
    if combined:
        return "read"
    # No permissions recorded — infer from role name
    return _infer_fallback_permission(role_name)


def _resolve_oaa_permissions(action: str) -> List[OAAPermission]:
    """Return OAA permission list for a BeyondTrust action string."""
    action_lower = action.lower() if action else ""
    for key, perms in _ACTION_TO_OAA.items():
        if key in action_lower:
            return perms
    return _DEFAULT_OAA_PERMS


def build_oaa_payload(
    users: list,
    roles: list,
    global_roles: list,
    groups: list,
    policies: list,
    provider_name: str,
    datasource_name: str,
) -> CustomApplication:
    """Assemble the Veza OAA CustomApplication payload."""

    app = CustomApplication(
        name=datasource_name,
        application_type=provider_name,
        description="BeyondTrust Privilege Management Cloud — identity and role data",
    )

    # Define custom properties for local users
    app.property_definitions.define_local_user_property("email_address", OAAPropertyType.STRING)
    app.property_definitions.define_local_user_property("account_name", OAAPropertyType.STRING)
    app.property_definitions.define_local_user_property("last_signed_in", OAAPropertyType.STRING)
    app.property_definitions.define_local_user_property("created", OAAPropertyType.STRING)
    app.property_definitions.define_local_user_property("disabled", OAAPropertyType.STRING)

    # ------------------------------------------------------------------
    # 1. Collect all unique permission action strings from roles + global roles
    # ------------------------------------------------------------------
    permission_names: set[str] = set()
    for role in list(roles) + list(global_roles):
        for perm in role.get("allowPermissions") or []:
            action = (perm.get("action") or "").strip()
            if action:
                permission_names.add(action)

    # Ensure at least a basic set
    for fallback in ("read", "write", "admin"):
        permission_names.add(fallback)

    for pname in sorted(permission_names):
        oaa_perms = _resolve_oaa_permissions(pname)
        app.add_custom_permission(pname, oaa_perms)
        log.debug("Registered custom permission '%s' → %s", pname, oaa_perms)

    log.info("Registered %d custom permissions", len(permission_names))

    # ------------------------------------------------------------------
    # 2. Add Roles as OAA Local Roles
    # ------------------------------------------------------------------
    role_id_map: dict[str, str] = {}  # BT role UUID → OAA role name
    role_name_to_id: dict[str, str] = {}  # lowercase role name → role key in app.local_roles
    for role in roles:
        role_id = str(role.get("id", ""))
        role_name = (role.get("name") or role_id).strip()
        if not role_name:
            continue
        app.add_local_role(role_name, unique_id=role_id)
        role_id_map[role_id] = role_name
        role_name_to_id[role_name.lower()] = role_id
        log.debug("Added role: %s (%s)", role_name, role_id)

        # Assign permissions to the role
        # Note: local_roles is keyed by unique_id (role_id UUID) when unique_id is provided
        allow_perms = role.get("allowPermissions") or []
        perms_added = 0
        for perm in allow_perms:
            action = (perm.get("action") or "").strip()
            if action and action in permission_names:
                try:
                    app.local_roles[role_id].add_permissions([action])
                    perms_added += 1
                except Exception as exc:
                    log.warning("Could not add permission '%s' to role '%s': %s",
                                action, role_name, exc)
        if perms_added == 0:
            # Role has no allowPermissions from API — infer a fallback from the role name
            fallback = _infer_fallback_permission(role_name)
            try:
                app.local_roles[role_id].add_permissions([fallback])
                log.debug("Role '%s' has no allowPermissions — assigned fallback '%s'",
                          role_name, fallback)
            except Exception as exc:
                log.warning("Could not add fallback permission '%s' to role '%s': %s",
                            fallback, role_name, exc)

    log.info("Added %d roles", len(role_id_map))

    # ------------------------------------------------------------------
    # 2b. Add GlobalRoles as OAA Local Roles (API v3 only)
    # ------------------------------------------------------------------
    global_role_count = 0
    for role in global_roles:
        role_id = str(role.get("id", ""))
        role_name = (role.get("name") or role_id).strip()
        if not role_name:
            continue
        # Prefix to distinguish global roles from tenant roles
        display_name = f"[Global] {role_name}"
        global_unique_id = f"global-{role_id}"
        if global_unique_id in app.local_roles:
            continue
        app.add_local_role(display_name, unique_id=global_unique_id)
        role_id_map[global_unique_id] = display_name
        role_name_to_id[role_name.lower()] = global_unique_id
        role_name_to_id[display_name.lower()] = global_unique_id
        log.debug("Added global role: %s (%s)", display_name, role_id)

        allow_perms = role.get("allowPermissions") or []
        perms_added = 0
        for perm in allow_perms:
            action = (perm.get("action") or "").strip()
            if action and action in permission_names:
                try:
                    app.local_roles[global_unique_id].add_permissions([action])
                    perms_added += 1
                except Exception as exc:
                    log.warning("Could not add permission '%s' to global role '%s': %s",
                                action, display_name, exc)
        if perms_added == 0:
            fallback = _infer_fallback_permission(role_name)
            try:
                app.local_roles[global_unique_id].add_permissions([fallback])
                log.debug("Global role '%s' has no allowPermissions — assigned fallback '%s'",
                          display_name, fallback)
            except Exception as exc:
                log.warning("Could not add fallback permission '%s' to global role '%s': %s",
                            fallback, display_name, exc)
        global_role_count += 1

    log.info("Added %d global roles", global_role_count)

    # ------------------------------------------------------------------
    # 3. Add Policies as OAA Application Resources
    # ------------------------------------------------------------------
    policy_resources: Dict[str, object] = {}  # policy_id → CustomResource
    for policy in policies:
        policy_id = str(policy.get("id", ""))
        policy_name = (policy.get("name") or policy_id).strip()
        if not policy_name:
            continue
        resource = app.add_resource(
            name=policy_name,
            resource_type="Policy",
            unique_id=policy_id,
            description=policy.get("description") or "",
        )
        policy_resources[policy_id] = resource
        log.debug("Added policy resource: %s", policy_name)

    log.info("Added %d policy resources", len(policies))

    # ------------------------------------------------------------------
    # 4. Add Groups as OAA Application Resources (sub-type)
    # ------------------------------------------------------------------
    for group in groups:
        group_id = str(group.get("id", ""))
        group_name = (group.get("name") or group_id).strip()
        if not group_name:
            continue
        app.add_resource(
            name=group_name,
            resource_type="ComputerGroup",
            unique_id=group_id,
            description=group.get("description") or "",
        )
        log.debug("Added group resource: %s", group_name)

    log.info("Added %d computer group resources", len(groups))

    # ------------------------------------------------------------------
    # 5. Add Users as OAA Local Users + assign roles
    # ------------------------------------------------------------------
    users_added = 0
    for user in users:
        user_id = str(user.get("id", ""))
        # Prefer accountName, fall back to emailAddress
        account_name = (user.get("accountName") or "").strip()
        email = (user.get("emailAddress") or "").strip()
        unique_name = account_name or email or user_id
        if not unique_name:
            continue

        is_active = not user.get("disabled", False)
        local_user = app.add_local_user(
            name=unique_name,
            unique_id=user_id,
        )
        local_user.is_active = is_active

        # Custom properties
        if email:
            local_user.set_property("email_address", email)
        if account_name and email:
            local_user.set_property("account_name", account_name)
        last_signed_in = user.get("lastSignedIn")
        if last_signed_in:
            local_user.set_property("last_signed_in", str(last_signed_in))
        created = user.get("created")
        if created:
            local_user.set_property("created", str(created))
        if user.get("disabled"):
            local_user.set_property("disabled", "true")

        # Assign roles to user
        # Try UUID first (roles keyed by unique_id), fall back to name-based lookup.
        # apply_to_application=True is required so the SDK serialises the assignment
        # into identity_to_permissions (None/False causes the entry to be skipped).
        user_roles = user.get("roles") or []
        for role_item in user_roles:
            role_item_id = str(role_item.get("id") or "")
            role_name_from_item = (role_item.get("name") or "").strip()
            if role_item_id and role_item_id in app.local_roles:
                role_key = role_item_id
            elif role_name_from_item and role_name_from_item.lower() in role_name_to_id:
                role_key = role_name_to_id[role_name_from_item.lower()]
            else:
                log.debug(
                    "User '%s' references unknown role '%s' — skipping",
                    unique_name,
                    role_name_from_item or role_item_id,
                )
                continue
            local_user.add_role(role_key, apply_to_application=True)
            log.debug("User '%s' → role '%s'", unique_name, role_id_map.get(role_key, role_key))

        users_added += 1

    log.info("Added %d users", users_added)
    return app


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------

def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool,
    save_json: bool,
) -> None:
    """Optionally save JSON, then push the OAA payload to Veza."""

    if save_json:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        json_path = os.path.join(
            script_dir,
            f"beyondtrust_epm_payload_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json",
        )
        import json as _json
        with open(json_path, "w", encoding="utf-8") as fh:
            _json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("Saved JSON payload to %s", json_path)
        print(f"Payload saved → {json_path}")

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping Veza push")
        print("[DRY RUN] Payload built successfully — Veza push skipped.")
        return

    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        log.info(
            "Pushing OAA payload to Veza (provider='%s', datasource='%s') …",
            provider_name,
            datasource_name,
        )
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Successfully pushed to Veza")
        print("Successfully pushed to Veza.")
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error,
            exc.message,
            exc.status_code,
        )
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    _setup_logging(args.log_level)

    print("=" * 60)
    print(" BeyondTrust EPM → Veza OAA Integration")
    print("=" * 60)

    # Load and validate config
    config = load_config(args)
    validate_config(config, args.dry_run)

    log.info(
        "Starting BeyondTrust EPM OAA integration — provider='%s' datasource='%s'",
        args.provider_name,
        args.datasource_name,
    )

    # Connect to BeyondTrust PM Cloud
    bt_client = BeyondTrustClient(
        base_url=config["bt_url"],
        client_id=config["bt_client_id"],
        client_secret=config["bt_client_secret"],
        page_size=args.page_size,
    )
    bt_client.authenticate()

    # Collect data
    users = bt_client.get_users()
    roles = bt_client.get_roles()
    global_roles = bt_client.get_global_roles()
    groups = bt_client.get_groups()
    policies = bt_client.get_policies()

    log.info(
        "Data collected — users: %d, roles: %d, global_roles: %d, groups: %d, policies: %d",
        len(users),
        len(roles),
        len(global_roles),
        len(groups),
        len(policies),
    )

    # Build OAA payload
    app = build_oaa_payload(
        users=users,
        roles=roles,
        global_roles=global_roles,
        groups=groups,
        policies=policies,
        provider_name=args.provider_name,
        datasource_name=args.datasource_name,
    )

    # Push (or dry-run)
    push_to_veza(
        veza_url=config["veza_url"],
        veza_api_key=config["veza_api_key"],
        provider_name=args.provider_name,
        datasource_name=args.datasource_name,
        app=app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )

    log.info("Integration complete")


if __name__ == "__main__":
    main()
