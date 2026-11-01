"""Config flow for Apple Music integration."""
from __future__ import annotations

from collections.abc import Mapping
import logging
from typing import Any

import aiohttp
import voluptuous as vol
from homeassistant.config_entries import ConfigFlow, ConfigFlowResult
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.selector import (
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)

from .const import CONF_API_KEY, CONF_HOST, CONF_PORT, DEFAULT_NAME, DEFAULT_PORT, DOMAIN

_LOGGER = logging.getLogger(__name__)

_API_KEY_SELECTOR = TextSelector(TextSelectorConfig(type=TextSelectorType.PASSWORD))

# Used by the user and reconfigure steps. The API key is optional: the frontend
# omits a blank optional field, so it's read with .get().
CONNECTION_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_HOST): str,
        vol.Required(CONF_PORT, default=DEFAULT_PORT): int,
        vol.Optional(CONF_API_KEY): _API_KEY_SELECTOR,
    }
)

REAUTH_SCHEMA = vol.Schema({vol.Required(CONF_API_KEY): _API_KEY_SELECTOR})


def _api_key_from(user_input: Mapping[str, Any]) -> str | None:
    """Return the entered API key, or None when the field was left blank."""
    return (user_input.get(CONF_API_KEY) or "").strip() or None


def _with_api_key(data: Mapping[str, Any], api_key: str | None) -> dict[str, Any]:
    """Copy of entry data with the API key set, or removed when there is none."""
    new_data = {k: v for k, v in data.items() if k != CONF_API_KEY}
    if api_key:
        new_data[CONF_API_KEY] = api_key
    return new_data


def _host_port(data: Mapping[str, Any]) -> dict[str, Any]:
    """Host/port suggestions for a form (never the API key)."""
    return {k: data[k] for k in (CONF_HOST, CONF_PORT) if k in data}


class AppleMusicConfigFlow(ConfigFlow, domain=DOMAIN):
    """Handle the config flow for Apple Music."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict | None = None
    ) -> ConfigFlowResult:
        """Handle the initial setup step shown in the UI."""
        errors: dict[str, str] = {}

        if user_input is not None:
            host = user_input[CONF_HOST].strip()
            port = user_input[CONF_PORT]
            api_key = _api_key_from(user_input)

            # Prevent duplicate entries for the same host:port
            await self.async_set_unique_id(f"{host}:{port}")
            self._abort_if_unique_id_configured()

            # Test the connection before accepting
            error = await self._test_connection(host, port, api_key)
            if error:
                errors["base"] = error
            else:
                return self.async_create_entry(
                    title=f"Apple Music ({host})",
                    data=_with_api_key({CONF_HOST: host, CONF_PORT: port}, api_key),
                )

        return self.async_show_form(
            step_id="user",
            data_schema=self.add_suggested_values_to_schema(
                CONNECTION_SCHEMA, _host_port(user_input or {})
            ),
            errors=errors,
        )

    async def async_step_reconfigure(
        self, user_input: dict | None = None
    ) -> ConfigFlowResult:
        """Change the API key (or re-test host/port) of an existing entry."""
        entry = self._get_reconfigure_entry()
        errors: dict[str, str] = {}

        if user_input is not None:
            host = user_input[CONF_HOST].strip()
            port = user_input[CONF_PORT]
            api_key = _api_key_from(user_input)

            # host:port is the unique ID; a different server needs a new entry
            await self.async_set_unique_id(f"{host}:{port}")
            self._abort_if_unique_id_mismatch()

            error = await self._test_connection(host, port, api_key)
            if error:
                errors["base"] = error
            else:
                return self.async_update_reload_and_abort(
                    entry,
                    data=_with_api_key(
                        {**entry.data, CONF_HOST: host, CONF_PORT: port}, api_key
                    ),
                )

        return self.async_show_form(
            step_id="reconfigure",
            data_schema=self.add_suggested_values_to_schema(
                CONNECTION_SCHEMA, _host_port(user_input or entry.data)
            ),
            errors=errors,
        )

    async def async_step_reauth(
        self, entry_data: Mapping[str, Any]
    ) -> ConfigFlowResult:
        """Start reauth after the server rejected our requests (401/403)."""
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict | None = None
    ) -> ConfigFlowResult:
        """Ask for the server's API key and test it."""
        entry = self._get_reauth_entry()
        host = entry.data[CONF_HOST]
        port = entry.data[CONF_PORT]
        errors: dict[str, str] = {}

        if user_input is not None:
            api_key = _api_key_from(user_input)
            error = await self._test_connection(host, port, api_key)
            if error:
                errors["base"] = error
            else:
                return self.async_update_reload_and_abort(
                    entry, data=_with_api_key(entry.data, api_key)
                )

        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=REAUTH_SCHEMA,
            errors=errors,
            description_placeholders={"host": f"{host}:{port}"},
        )

    async def _test_connection(
        self, host: str, port: int, api_key: str | None = None
    ) -> str | None:
        """Try to reach the server. Returns an error key or None on success."""
        session = async_get_clientsession(self.hass)
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        try:
            async with session.get(
                f"http://{host}:{port}/_ping",
                timeout=aiohttp.ClientTimeout(total=5),
                headers=headers,
            ) as resp:
                # 401: key missing/wrong, 403: HA's IP not in ALLOWED_IPS
                if resp.status in (401, 403):
                    return "invalid_auth"
                if resp.status != 200:
                    return "cannot_connect"
                return None
        except (aiohttp.ClientConnectorError, TimeoutError):
            return "cannot_connect"
        except aiohttp.InvalidURL:
            return "invalid_host"
        except Exception:  # pylint: disable=broad-except
            _LOGGER.exception("Unexpected error connecting to Apple Music API")
            return "unknown"
