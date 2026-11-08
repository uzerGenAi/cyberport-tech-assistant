# Data sources

The demo data for the Cyberport Tech Assistant comes from three public Kaggle datasets plus
illustrative content written for this project. **This is a reference demo. It is not affiliated
with or endorsed by Cyberport SE**, and none of the stock, order, promotion or policy data below
is Cyberport's.

Rebuild the catalog and orders with:

```bash
pip install pandas   # only this script needs it; the runtime does not
python3 2_data_strategy/build_from_kaggle.py
```

The script downloads the datasets (public, no Kaggle token needed) into
`2_data_strategy/kaggle_source/` (gitignored) and rewrites the two generated files.

## From Kaggle

| File | Kaggle dataset | Licence | What is used |
|---|---|---|---|
| `menu/menu_records.json` (smartphones) | [Smartphones Price Dataset](https://www.kaggle.com/datasets/juanmerinobermejo/smartphones-price-dataset) by Juan Merino Bermejo | Apache 2.0 | Brand, model, RAM, storage, colour and price in € as listed by the Spanish retailer PcComponentes (data from April 2024) |
| `menu/menu_records.json` (laptops) | [Laptops Price Dataset](https://www.kaggle.com/datasets/juanmerinobermejo/laptops-price-dataset) by Juan Merino Bermejo | Apache 2.0 | Brand, model, CPU, RAM, storage, GPU, screen, touchscreen, new or refurbished, and price in € from PcComponentes (data from July 2023) |
| `orders/orders_records.json` | [Customer purchase behavior - Electronic Sales Data](https://www.kaggle.com/datasets/cameronseamons/electronic-sales-sep2023-sep2024) by Cameron Seamons | MIT | Customer ID, purchase date, order status, quantity, shipping type and payment method from 24 smartphone and laptop transactions |

### How the Kaggle data is transformed

- **Catalog curation.** The source has 1,816 phone listings and 2,160 laptop listings. The script keeps
  124 products so that `get_menu`, which returns the whole catalog to the model, stays at about 67 KB.
  - **Smartphones:** listings without an operator contract, without bundled accessories and not
    refurbished. Each model becomes one product. The `prices_by_size_eur` field holds the lowest
    listed price per storage size.
  - **Laptops:** one configuration per model name, the cheapest. Categories are derived from the
    name and specs: gaming, business, premium, everyday and refurbished. Laptops with a
    Portuguese keyboard are excluded.
  - **Clean-up:** Spanish colour words are translated or removed from names.
- **Orders.** Each Kaggle transaction is mapped to a catalog product of the same type (smartphone or
  laptop) and re-priced from the catalog. Quantities above 2 are set to 1. "Same Day" and
  "Standard" shipping become click & collect at a demo store. The last four orders are moved to
  November 2026 with open statuses (PROCESSING, READY_FOR_PICKUP, SHIPPED) so the demo has
  orders in progress.

The prices are real retail prices from one Spanish retailer in 2023/2024. They are not current
German prices.

## Illustrative (written for this project)

| File | Content |
|---|---|
| `menu/menu_records.json` → `stock_by_store` | Synthetic per-store stock, generated deterministically from each product ID |
| `stores/stores_records.json` | 9 stores in cities where Cyberport lists stores (Burda reported 9 stores in Germany and Austria in February 2025). The Berlin, Hamburg, Leipzig, Dortmund and Bochum addresses match a public store listing (weekli.de, November 2026); the Dresden, Munich, Cologne and Vienna addresses are illustrative. Opening hours, coordinates and pickup stations are illustrative too. Check cyberport.de for the real store list. `has_drive_thru` means "has a 24/7 pickup station". |
| `promos/promos_records.json` | Demo promotions (trade-in bonus, student discount, financing and others) |
| `*/..._kb_faqs.txt` | Knowledge-base documents. The policies are modelled on typical German electronics retail. Statements about EU and German law (14-day withdrawal right, 2-year legal guarantee, USB-C rule, EU energy label, ElektroG take-back) describe the law, not a company policy. |

## Demo lookups

Order status needs both the customer ID and the order ID. Open orders in the sample data:

| Customer ID | Order ID | Status |
|---|---|---|
| `customer_7977` | `ord_7977_021` | PROCESSING |
| `customer_17485` | `ord_17485_022` | READY_FOR_PICKUP |
| `customer_2055` | `ord_2055_023` | SHIPPED |
| `customer_3670` | `ord_3670_024` | READY_FOR_PICKUP |
