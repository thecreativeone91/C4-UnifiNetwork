-- UniFi PDU Outlet (Open Source) - child of the UniFi Network driver.
--
-- Switches one outlet of a UniFi SmartPower PDU (USP-PDU-Pro, PDU-Pro-HD,
-- USP-Strip, USP-Plug...) on, off or through a power cycle.

DRIVER_VERSION = "1.0.1"

local ChildCore = require("child_core")

UNIFI_TEST = ChildCore.run({
  kind = "outlet",
  itemWord = "Outlet",
  itemProperty = "Outlet",
  nameProperty = "Outlet Name",
  logPrefix = "UniFi PDU Outlet: ",
  version = DRIVER_VERSION,
})
