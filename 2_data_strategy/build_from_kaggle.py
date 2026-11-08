#!/usr/bin/env python3
"""Build the electronics demo data from public Kaggle datasets.

Writes:
  menu/menu_records.json      product catalog read by the catalog agent (get_menu, pricing)
  orders/orders_records.json  sample orders loaded into spbc-orders-table

Sources (see SOURCES.md for licences and what is synthetic):
  juanmerinobermejo/smartphones-price-dataset   Apache 2.0, EUR prices (PcComponentes)
  juanmerinobermejo/laptops-price-dataset       Apache 2.0, EUR prices (PcComponentes)
  cameronseamons/electronic-sales-sep2023-sep2024  MIT, order transactions

The raw CSVs are cached in kaggle_source/ (gitignored). Needs pandas (pip install pandas), which
the runtime does not use. Run from any directory:
  python3 2_data_strategy/build_from_kaggle.py

The catalog is deliberately curated to about 140 products: get_menu returns the whole file to
the model on every catalog question, so it has to stay small.
"""
import hashlib
import json
import random
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
CACHE = HERE / "kaggle_source"
STORES_FILE = HERE / "stores" / "stores_records.json"
CATALOG_FILE = HERE / "menu" / "menu_records.json"
ORDERS_FILE = HERE / "orders" / "orders_records.json"

DATASETS = {
    "smartphones": ("juanmerinobermejo/smartphones-price-dataset", "smartphones.csv"),
    "laptops": ("juanmerinobermejo/laptops-price-dataset", "laptops.csv"),
    "sales": ("cameronseamons/electronic-sales-sep2023-sep2024", "Electronic_sales_Sep2023-Sep2024.csv"),
}

# Spanish words in the PcComponentes product names, mapped to English (None = drop the word).
SPANISH_WORDS = {
    "gris espacial": "Space Gray", "negro espacial": "Space Black", "blanco estrella": "Starlight",
    "luz estelar": "Starlight", "medianoche": "Midnight", "plata": "Silver", "dorado": "Gold",
    "oro": "Gold", "negro": "Black", "blanco": "White", "azul": "Blue", "verde": "Green",
    "rosa": "Pink", "púrpura": "Purple", "morado": "Purple", "rojo": "Red", "amarillo": "Yellow",
    "gris": "Gray", "platino": "Platinum", "grafito": "Graphite", "táctil": None, "libre": None,
}


def download(key: str) -> Path:
    """Download one Kaggle dataset (public, no token needed) and return the CSV path."""
    ref, filename = DATASETS[key]
    target = CACHE / key / filename
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    archive = target.parent / "archive.zip"
    url = f"https://www.kaggle.com/api/v1/datasets/download/{ref}"
    print(f"Downloading {ref} ...")
    urllib.request.urlretrieve(url, archive)
    with zipfile.ZipFile(archive) as zf:
        zf.extract(filename, target.parent)
    archive.unlink()
    return target


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def storage_label(gb: float) -> str:
    gb = int(gb)
    return f"{gb // 1000}TB" if gb >= 1000 else f"{gb}GB"


def seeded(item_id: str) -> random.Random:
    return random.Random(int(hashlib.sha256(item_id.encode()).hexdigest()[:12], 16))


def synthetic_stock(item_id: str, store_ids: list, demand: float) -> dict:
    """Illustrative per-store stock. Popular products are stocked in more stores."""
    rng = seeded(item_id)
    share = 0.35 + 0.45 * demand          # 35-80 % of stores carry the product
    stock = {}
    for store_id in store_ids:
        if rng.random() < share:
            stock[store_id] = rng.randint(1, 12 if demand > 0.6 else 6)
    if not stock:                          # every product is in stock somewhere
        stock[store_ids[0]] = 2
    return stock


# ── Smartphones ───────────────────────────────────────────────────────────────

PHONE_CAPS = {  # how many models per brand make it into the curated catalog
    "Samsung": 14, "Apple": 11, "Xiaomi": 9, "Google": 5, "Motorola": 5, "OnePlus": 4,
    "OPPO": 3, "Honor": 3, "POCO": 3, "Realme": 3, "Nothing": 2, "Fairphone": 2,
    "Sony": 2, "Nokia": 2, "Vivo": 2, "Doro": 1,
}
STORAGE_TOKEN = re.compile(r"\s(\d+\s?/\s?\d+\s?(?:GB|TB)|\d+\s?(?:GB|TB))\b", re.I)


def build_phones(store_ids: list) -> list:
    df = pd.read_csv(download("smartphones"))
    df = df[(df["Free"] == "Yes") & df["Storage"].notna() & df["Final Price"].notna()]
    df = df[~df["Smartphone"].str.contains(r"\+|Reacondicionado|Importaci|Importad", regex=True)]
    df["base"] = df["Smartphone"].apply(lambda n: STORAGE_TOKEN.split(n)[0].strip())
    df = df[df["base"] != df["Smartphone"]]            # no storage in the name: unparseable
    df["base"] = df["base"].apply(clean_name)
    # Normalise the brand prefix ("Oppo A74" -> "OPPO A74").
    df["base"] = df.apply(lambda r: re.sub(rf"^{re.escape(r.Brand)}\b", r.Brand, r.base, flags=re.I), axis=1)

    records = []
    for brand, cap in PHONE_CAPS.items():
        models = df[df["Brand"] == brand].groupby("base")
        ranked = sorted(models, key=lambda kv: (-len(kv[1]), -kv[1]["Final Price"].median()))[:cap]
        for base, rows in ranked:
            # Lowest listed price per storage size, ordered by storage size (not by price:
            # the source sometimes lists a larger size cheaper, and that is kept as listed).
            prices = {storage_label(gb): round(float(g["Final Price"].min()), 2)
                      for gb, g in sorted(rows.groupby("Storage"), key=lambda kv: kv[0]) if gb >= 16}
            if not prices:
                continue
            item_id = "phone_" + slug(base)
            low = min(prices.values())
            if re.search(r"Flip|Fold|Razr", base, re.I):
                segment = "Foldable"
            elif low >= 800:
                segment = "Flagship"
            elif low >= 350:
                segment = "Mid-range"
            else:
                segment = "Budget"
            demand = min(len(rows) / 15, 1.0)
            attributes = {"brand": brand, "segment": segment}
            ram = rows["RAM"].dropna()
            if not ram.empty:
                attributes["ram_gb"] = int(ram.max())
            attributes.update({
                "colors": sorted(set(rows["Color"].dropna()))[:6],
                "popularity_score": int(50 + 49 * demand),
                "stock_by_store": synthetic_stock(item_id, store_ids, demand),
            })
            records.append({
                "item_id": item_id,
                "name": base,
                "category": "smartphones",
                "price_eur": low,
                "prices_by_size_eur": prices,
                "attributes_json": attributes,
            })
    return records


# ── Laptops ───────────────────────────────────────────────────────────────────

CPU_START = re.compile(r"\s(Intel|AMD|Apple M\d|Mediatek|MediaTek|Qualcomm)\b")
BUSINESS = re.compile(r"ExpertBook|ThinkPad|ThinkBook|EliteBook|ProBook|Latitude|Vostro|TravelMate", re.I)
PREMIUM = re.compile(r"MacBook|Surface|XPS|Zenbook|Spectre|Envy|Gram|Galaxy Book|Yoga|Swift|Creator|OLED|Prestige", re.I)
GAMING = re.compile(r"ROG|TUF|Strix|Zephyrus|Legion|Gaming|Katana|Raider|Stealth|Pulse|Crosshair|Sword|"
                    r"Cyborg|Vector|Titan|Alpha|Bravo|Delta|Thin GF|OMEN|Victus|Nitro|Predator|AORUS|"
                    r"Blade|Alienware|\bG15\b|\bG16\b", re.I)
NAME_FIXES = [(re.compile(r"\bMacbook\b"), "MacBook"), (re.compile(r"^Msi\b"), "MSI"),
              (re.compile(r"\bASUS\b|\bAsus\b"), "ASUS")]
CATEGORY_TARGETS = {"gaming_laptops": 16, "premium_laptops": 14, "everyday_laptops": 14,
                    "business_laptops": 10, "refurbished_laptops": 6}


def english_colors(tail: str) -> list:
    text = tail.lower()
    colors = []
    for spanish, english in sorted(SPANISH_WORDS.items(), key=lambda kv: -len(kv[0])):
        if spanish in text:
            text = text.replace(spanish, " ")
            if english and english not in colors:
                colors.append(english)
    return colors


def clean_name(name: str) -> str:
    """Drop Spanish colour words from a product name and fix brand casing."""
    for spanish in sorted(SPANISH_WORDS, key=len, reverse=True):
        name = re.sub(rf"\s{re.escape(spanish)}\b", "", name, flags=re.I)
    for pattern, replacement in NAME_FIXES:
        name = pattern.sub(replacement, name)
    return re.sub(r"\s{2,}", " ", name).strip()


def laptop_category(row) -> str:
    if row["Status"] == "Refurbished":
        return "refurbished_laptops"
    name = row["Laptop"]
    gpu = str(row["GPU"]) if pd.notna(row["GPU"]) else ""
    dedicated = bool(re.match(r"(RTX|GTX|RX)", gpu))
    if BUSINESS.search(name):
        return "business_laptops"
    if dedicated and GAMING.search(name):
        return "gaming_laptops"
    if PREMIUM.search(name):
        return "premium_laptops"
    return "everyday_laptops"


def build_laptops(store_ids: list) -> list:
    df = pd.read_csv(download("laptops"))
    df = df[df["Final Price"].notna() & ~df["Laptop"].str.contains(r"\(PT\)|\+", regex=True)]
    parsed = []
    for _, row in df.iterrows():
        match = CPU_START.search(row["Laptop"])
        if not match:
            continue
        name = clean_name(row["Laptop"][:match.start()])
        specs = row["Laptop"][match.start():].strip()
        cpu = specs.split("/")[0].strip()
        tail = re.split(r'["\x94”]', specs)[-1]
        model_count = int((df["Model"] == row["Model"]).sum())
        parsed.append({
            "name": name, "cpu": cpu, "row": row, "colors": english_colors(tail),
            "category": laptop_category(row), "model_count": model_count,
        })

    # One product per name; the cheapest configuration wins.
    by_name = {}
    for p in sorted(parsed, key=lambda p: p["row"]["Final Price"]):
        by_name.setdefault(p["name"].lower(), p)

    records = []
    for category, target in CATEGORY_TARGETS.items():
        pool = sorted((p for p in by_name.values() if p["category"] == category),
                      key=lambda p: (-p["model_count"], p["row"]["Final Price"]))
        chosen, per_brand, per_model = [], {}, set()
        for p in pool:
            brand, model = p["row"]["Brand"], (p["row"]["Brand"], p["row"]["Model"])
            if per_brand.get(brand, 0) >= 3 or model in per_model:
                continue
            chosen.append(p)
            per_brand[brand] = per_brand.get(brand, 0) + 1
            per_model.add(model)
            if len(chosen) == target:
                break
        for p in chosen:
            row = p["row"]
            item_id = "laptop_" + slug(p["name"])
            demand = min(p["model_count"] / 40, 1.0)
            gpu = row["GPU"] if pd.notna(row["GPU"]) else "Integrated graphics"
            storage_type = row["Storage type"] if pd.notna(row["Storage type"]) else "flash"
            attributes = {
                "brand": "ASUS" if row["Brand"] == "Asus" else row["Brand"],
                "cpu": p["cpu"], "ram_gb": int(row["RAM"]),
                "storage": f"{storage_label(row['Storage'])} {storage_type}",
                "gpu": gpu, "screen_inches": float(row["Screen"]),
                "touchscreen": row["Touch"] == "Yes", "condition": row["Status"],
            }
            if p["colors"]:
                attributes["colors"] = p["colors"]
            attributes["popularity_score"] = int(50 + 49 * demand)
            attributes["stock_by_store"] = synthetic_stock(item_id, store_ids, demand)
            records.append({
                "item_id": item_id, "name": p["name"], "category": category,
                "price_eur": round(float(row["Final Price"]), 2), "attributes_json": attributes,
            })
    return records


# ── Orders ────────────────────────────────────────────────────────────────────

def build_orders(catalog: list, store_ids: list) -> list:
    """Sample orders: dates, status, quantity and payment come from the Kaggle sales data;
    each line is mapped to a catalog product of the same type and priced from the catalog."""
    df = pd.read_csv(download("sales"))
    df = df[df["Product Type"].isin(["Smartphone", "Laptop"])].sort_values("Purchase Date")
    phones = [r for r in catalog if r["category"] == "smartphones"]
    laptops = [r for r in catalog if r["category"].endswith("_laptops")]
    rng = random.Random(42)
    sample = df.groupby("Customer ID").head(1).sample(n=24, random_state=7).sort_values("Purchase Date")
    orders = []
    for n, (_, row) in enumerate(sample.iterrows(), start=1):
        product = rng.choice(phones if row["Product Type"] == "Smartphone" else laptops)
        quantity = 1 if row["Quantity"] > 2 else int(row["Quantity"])
        item = {"item_id": product["item_id"], "name": product["name"], "quantity": quantity}
        unit = product["price_eur"]
        if product.get("prices_by_size_eur"):
            variant = next(iter(product["prices_by_size_eur"]))
            item["variant"] = variant
            unit = product["prices_by_size_eur"][variant]
        collect = row["Shipping Type"] in {"Same Day", "Standard"}
        if row["Order Status"] == "Cancelled":
            status = "CANCELLED"
        else:
            status = "COLLECTED" if collect else "DELIVERED"
        orders.append({
            "user_id": f"customer_{int(row['Customer ID'])}",
            "order_timestamp": f"{row['Purchase Date']}T{10 + n % 9:02d}:{(n * 7) % 60:02d}:00Z",
            "order_id": f"ord_{int(row['Customer ID'])}_{n:03d}",
            "status": status,
            "items": [item],
            "store_id": rng.choice(store_ids) if collect else "online",
            "fulfilment": "click_and_collect" if collect else "home_delivery",
            "payment_method": str(row["Payment Method"]).replace("Paypal", "PayPal"),
            "total_amount": round(unit * quantity, 2),
        })
    # The Kaggle orders are all finished (2023-2024). Move the last four to November 2026 with
    # open statuses, so the demo has orders that are still in progress.
    open_statuses = ["PROCESSING", "READY_FOR_PICKUP", "SHIPPED", "READY_FOR_PICKUP"]
    for offset, (order, status) in enumerate(zip(orders[-4:], open_statuses)):
        order["order_timestamp"] = f"2026-11-0{3 + offset}T{order['order_timestamp'][11:]}"
        if status == "READY_FOR_PICKUP" and order["fulfilment"] != "click_and_collect":
            order["fulfilment"], order["store_id"] = "click_and_collect", rng.choice(store_ids)
        if status == "SHIPPED" and order["fulfilment"] != "home_delivery":
            order["fulfilment"], order["store_id"] = "home_delivery", "online"
        order["status"] = status
    return orders


def main() -> int:
    stores = json.loads(STORES_FILE.read_text(encoding="utf-8"))
    store_ids = [s["store_id"] for s in stores]
    catalog = build_phones(store_ids) + build_laptops(store_ids)
    ids = [r["item_id"] for r in catalog]
    if len(ids) != len(set(ids)):
        print("Duplicate item_id values in the catalog", file=sys.stderr)
        return 1
    CATALOG_FILE.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    orders = build_orders(catalog, store_ids)
    ORDERS_FILE.write_text(json.dumps(orders, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    counts = pd.Series([r["category"] for r in catalog]).value_counts().to_dict()
    print(f"Catalog: {len(catalog)} products {counts}, {CATALOG_FILE.stat().st_size // 1024} KB")
    print(f"Orders:  {len(orders)} orders")
    return 0


if __name__ == "__main__":
    sys.exit(main())
