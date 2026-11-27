"""Read the current system-wide resource and power counters, as JSON."""
import json
import os
from pathlib import Path
import time
from time import sleep

GIB = 1024**3
SUPPLIES = Path("/sys/class/power_supply")


def text(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def number(path):
    try:
        return int(text(path))
    except ValueError:
        return None


def cpu_counters():
    with Path("/proc/stat").open() as cpu_stat:
        counters = [int(value) for value in cpu_stat.readline().split()[1:9]]
    return sum(counters), counters[3] + counters[4]


def memory():
    amounts = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        name, _, value = line.partition(":")
        if name in {"MemTotal", "MemAvailable"}:
            amounts[name] = int(value.split()[0]) * 1024 / GIB
    total = amounts["MemTotal"]
    return max(0, total - amounts["MemAvailable"]), total


def temperature():
    found = []
    for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
        if text(zone / "type").lower().startswith(("cpu", "x86_pkg_temp", "soc_thermal")):
            milli = number(zone / "temp")
            if milli is not None and 0 < milli < 150000:
                found.append(milli / 1000)
    return max(found, default=None)


LAST_DRAW = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "afterlight/last-draw.json"


def power():
    """Watts in from chargers, into (+) or out of (-) the battery, and what the
    system uses. Some USB-C chargers report current but no voltage; then the
    system's use is the last reading on battery, and `estimated` says so."""
    measured_in, unknown_in, battery, adapters = 0.0, False, None, []
    for supply in sorted(SUPPLIES.glob("*")):
        kind = text(supply / "type")
        if kind == "Battery":
            if battery is None and text(supply / "scope") != "Device" and number(supply / "present") != 0:
                battery = supply
            continue
        if kind in {"Mains", "Wireless"} or kind.startswith("USB"):
            online = number(supply / "online")
            if online in (0, 1):
                adapters.append(online)
            if online == 1:
                volts, amps = number(supply / "voltage_now"), number(supply / "current_now")
                if volts and amps:
                    measured_in += volts * amps / 1e12
                elif amps:
                    unknown_in = True
    status = text(battery / "status").lower().replace(" ", "_") if battery else ""
    reading = {"external": any(adapters) if adapters else None, "status": status,
               "inWatts": round(measured_in, 2), "estimated": False}
    if battery is None:
        return reading
    rate = number(battery / "power_now")
    if rate is None:
        current, voltage = number(battery / "current_now"), number(battery / "voltage_now")
        if current is not None and voltage:
            rate = current * voltage / 1_000_000
    if rate is None:
        return {**reading, "percent": number(battery / "capacity")}
    flow = abs(rate) / 1_000_000
    if status == "discharging":
        flow = -flow
    elif status != "charging":
        flow = 0.0 if flow < 0.05 else flow * (1 if rate > 0 else -1)

    system = max(0.0, measured_in - flow)
    if status == "discharging" and not unknown_in:
        # A true reading of the system's use: keep it for charging time.
        try:
            LAST_DRAW.parent.mkdir(parents=True, exist_ok=True)
            LAST_DRAW.write_text(json.dumps({"watts": system, "time": time.time()}))
        except OSError:
            pass
    elif unknown_in and flow >= 0:
        try:
            last = json.loads(LAST_DRAW.read_text())
            if time.time() - last["time"] < 86400:
                system = float(last["watts"])
                reading["inWatts"] = round(flow + system, 2)
                reading["estimated"] = True
        except (OSError, ValueError, KeyError, TypeError):
            reading["inWatts"], system = None, None
    return {**reading, "percent": number(battery / "capacity"),
            "batteryWatts": flow, "systemWatts": system}


def screen():
    for device in sorted(Path("/sys/class/backlight").glob("*")):
        now, top = number(device / "brightness"), number(device / "max_brightness")
        if now is not None and top:
            return round(100 * now / top)
    return None


def snapshot():
    total_before, idle_before = cpu_counters()
    used, total = memory()
    storage = os.statvfs(Path.home())
    sleep(0.35)
    total_after, idle_after = cpu_counters()
    delta = total_after - total_before
    cpu = max(0, min(100, 100 * (delta - (idle_after - idle_before)) / delta)) if delta > 0 else None
    return {"cpu": cpu, "memoryUsed": used, "memoryTotal": total,
            "storageAvailable": storage.f_bavail * storage.f_frsize / GIB,
            "temperature": temperature(), "power": power(), "screen": screen()}


if __name__ == "__main__":
    print(json.dumps(snapshot(), allow_nan=False))
