# Data sources

The Cyberport Tech Assistant is built for Cyberport (client project).

## Company data (supplied by Cyberport)

| File | What it holds |
|---|---|
| `menu/menu_records.json` | Smartphone and laptop catalog: brand, model, specifications and prices in € |
| `orders/orders_records.json` | Customer orders: customer ID, date, status, quantity, shipping type and payment method |

To change the catalog or the orders, edit these two files and run the loaders (`./deploy.sh only docs`
for the catalog in S3, `(cd 2_data_strategy/orders && python3 orders_load_helper_script.py)` for the
orders table).

## Illustrative (written for this project)

| File | Content |
|---|---|
| `menu/menu_records.json` → `stock_by_store` | Synthetic per-store stock, generated deterministically from each product ID |
| `stores/stores_records.json` | 9 stores in cities where Cyberport lists stores (Burda reported 9 stores in Germany and Austria in February 2025). The Berlin, Hamburg, Leipzig, Dortmund and Bochum addresses match a public store listing (weekli.de, November 2026); the Dresden, Munich, Cologne and Vienna addresses are illustrative. Opening hours, coordinates and pickup stations are illustrative too. Check cyberport.de for the real store list. `has_drive_thru` means "has a 24/7 pickup station". |
| `promos/promos_records.json` | Sample promotions (trade-in bonus, student discount, financing and others). Uploaded to the promotions S3 bucket once by Terraform as the starting file; later changes are made by uploading a new file to that bucket |
| `*/..._kb_faqs.txt` | Knowledge-base documents. The policies are modelled on typical German electronics retail. Statements about EU and German law (14-day withdrawal right, 2-year legal guarantee, USB-C rule, EU energy label, ElektroG take-back) describe the law, not a company policy. |

Replace each illustrative source with the matching Cyberport system before go-live.

## Demo lookups

Order status needs both the customer ID and the order ID. Open orders in the sample data:

| Customer ID | Order ID | Status |
|---|---|---|
| `customer_7977` | `ord_7977_021` | PROCESSING |
| `customer_17485` | `ord_17485_022` | READY_FOR_PICKUP |
| `customer_2055` | `ord_2055_023` | SHIPPED |
| `customer_3670` | `ord_3670_024` | READY_FOR_PICKUP |
