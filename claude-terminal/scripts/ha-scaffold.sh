#!/bin/bash

# ha-scaffold — Scaffold a new Home Assistant custom component or PyScript automation
# Usage: ha-scaffold <domain> [name] [description] OR ha-scaffold pyscript <name> [description]

set -euo pipefail

show_help() {
    cat << 'EOF'
ha-scaffold — Scaffold Home Assistant custom component or PyScript automation

Usage:
  ha-scaffold <domain> [friendly_name] [description]
  ha-scaffold pyscript <script_name> [description]

Examples:
  ha-scaffold solar_monitor "Solar Monitor" "Monitors solar inverter stats"
  ha-scaffold pyscript smart_hvac "Automated HVAC control script"
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    show_help
    exit 0
fi

if [ "$1" = "pyscript" ]; then
    SCRIPT_NAME="${2:-my_automation}"
    SCRIPT_NAME=$(echo "$SCRIPT_NAME" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    DESCRIPTION="${3:-PyScript automation script for $SCRIPT_NAME}"
    TARGET_DIR="/config/pyscript"
    TARGET_FILE="${TARGET_DIR}/${SCRIPT_NAME}.py"

    mkdir -p "$TARGET_DIR"
    
    if [ -f "$TARGET_FILE" ]; then
        echo "Error: File ${TARGET_FILE} already exists!" >&2
        exit 1
    fi

    cat << EOF > "$TARGET_FILE"
"""
${DESCRIPTION}
"""

@state_trigger("binary_sensor.front_door_motion == 'on'")
def ${SCRIPT_NAME}_handler():
    """Handler function executed on state change."""
    log.info(f"PyScript ${SCRIPT_NAME} triggered")
    # Example action: call a service
    # service.call("light", "turn_on", entity_id="light.hallway", brightness=255)
EOF
    echo "PyScript automation created at: ${TARGET_FILE}"
    exit 0
fi

DOMAIN="$1"
# Ensure domain is valid snake_case
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
NAME="${2:-$DOMAIN}"
DESCRIPTION="${3:-Custom component for $NAME}"
TARGET_DIR="/config/custom_components/${DOMAIN}"

if [ -d "$TARGET_DIR" ]; then
    echo "Error: Directory ${TARGET_DIR} already exists!" >&2
    exit 1
fi

echo "Scaffolding custom component in ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"

# 1. manifest.json
cat << EOF > "${TARGET_DIR}/manifest.json"
{
  "domain": "${DOMAIN}",
  "name": "${NAME}",
  "codeowners": [],
  "config_flow": true,
  "dependencies": [],
  "documentation": "https://github.com/custom-components/${DOMAIN}",
  "integration_type": "device",
  "iot_class": "local_polling",
  "issue_tracker": "https://github.com/custom-components/${DOMAIN}/issues",
  "requirements": [],
  "version": "1.0.0"
}
EOF

# 2. const.py
cat << EOF > "${TARGET_DIR}/const.py"
"""Constants for the ${NAME} integration."""

DOMAIN = "${DOMAIN}"
NAME = "${NAME}"
VERSION = "1.0.0"
EOF

# 3. __init__.py
cat << EOF > "${TARGET_DIR}/__init__.py"
"""The ${NAME} integration."""
from __future__ import annotations

import logging
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant

from .const import DOMAIN

_LOGGER = logging.getLogger(__name__)

PLATFORMS: list[Platform] = [Platform.SENSOR]

async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up ${NAME} from a config entry."""
    hass.data.setdefault(DOMAIN, {})
    hass.data[DOMAIN][entry.entry_id] = entry.data

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True

async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload a config entry."""
    if unload_ok := await hass.config_entries.async_unload_platforms(entry, PLATFORMS):
        hass.data[DOMAIN].pop(entry.entry_id)

    return unload_ok
EOF

# 4. config_flow.py
cat << EOF > "${TARGET_DIR}/config_flow.py"
"""Config flow for ${NAME} integration."""
from __future__ import annotations

import logging
from typing import Any
import voluptuous as vol

from homeassistant import config_entries
from homeassistant.data_entry_flow import FlowResult

from .const import DOMAIN, NAME

_LOGGER = logging.getLogger(__name__)

STEP_USER_DATA_SCHEMA = vol.Schema(
    {
        vol.Required("name", default=NAME): str,
    }
)

class ConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Handle a config flow for ${NAME}."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """Handle the initial step."""
        errors: dict[str, str] = {}

        if user_input is not None:
            return self.async_create_entry(title=user_input["name"], data=user_input)

        return self.async_show_form(
            step_id="user", data_schema=STEP_USER_DATA_SCHEMA, errors=errors
        )
EOF

# 5. sensor.py
cat << EOF > "${TARGET_DIR}/sensor.py"
"""Sensor platform for ${NAME}."""
from __future__ import annotations

from homeassistant.components.sensor import SensorEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, NAME

async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up sensor platform."""
    async_add_entities([ExampleSensor(entry.title)], True)

class ExampleSensor(SensorEntity):
    """Representation of an Example Sensor."""

    def __init__(self, name: str) -> None:
        """Initialize the sensor."""
        self._attr_name = f"{name} Status"
        self._attr_unique_id = f"{DOMAIN}_status"
        self._attr_native_value = "online"

    async def async_update(self) -> None:
        """Fetch new state data for the sensor."""
        self._attr_native_value = "online"
EOF

# 6. strings.json
cat << EOF > "${TARGET_DIR}/strings.json"
{
  "config": {
    "step": {
      "user": {
        "title": "${NAME}",
        "description": "Set up ${NAME} integration",
        "data": {
          "name": "Integration Name"
        }
      }
    }
  }
}
EOF

# 7. README.md
cat << EOF > "${TARGET_DIR}/README.md"
# ${NAME} (\`${DOMAIN}\`)

${DESCRIPTION}

## Files
- \`manifest.json\` - Component metadata
- \`__init__.py\` - Entry point & setup logic
- \`config_flow.py\` - UI configuration handler
- \`sensor.py\` - Sensor entity platform
EOF

echo "Scaffold complete for ${DOMAIN} in ${TARGET_DIR}."
echo "Created files: manifest.json, const.py, __init__.py, config_flow.py, sensor.py, strings.json, README.md"
