-- UniFi PoE Port (Open Source) - child of the UniFi Network driver.
--
-- Switches PoE power on one port of a UniFi switch or gateway on, off or
-- through a power cycle.

DRIVER_VERSION = "1.0.1"

local ChildCore = require("child_core")

UNIFI_TEST = ChildCore.run({
  kind = "poe",
  itemWord = "Port",
  itemProperty = "PoE Port",
  nameProperty = "Port Name",
  logPrefix = "UniFi PoE Port: ",
  version = DRIVER_VERSION,
})
