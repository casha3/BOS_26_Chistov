# Laboratory Work No. 2 — Work Log

## task_2_1.sh

Run:
```bash
chmod +x task_2_1.sh
./task_2_1.sh
./task_2_1.sh
```

Check the log:
```bash
cat /tmp/run.log
```

Expected result:
- stdout: `Hello, World!`
- stderr: number of previous runs (0, 1, 2…)
- `/tmp/run.log`: lines with date and time of each run

---

## task_2_2.sh

Run:
```bash
chmod +x task_2_2.sh
./task_2_2.sh
```

What it does:
- runs `task_2_1.sh`
- opens `/tmp/run.log` in `less`

Exit `less` with `q`.

---

## task_2_3.sh

Run with input redirection:
```bash
cat /etc/passwd | ./task_2_3.sh
```

Or with file redirection:
```bash
./task_2_3.sh < /etc/passwd
```

Save matched lines to a file:
```bash
./task_2_3.sh < /etc/passwd 2> only_bin.txt
cat only_bin.txt
```

---

## task_2_4.sh

Create a test file in the home directory:
```bash
echo 111 > ~/newnew.txt
```

Run:
```bash
chmod +x task_2_4.sh
./task_2_4.sh
```

Expected result:
```
list of files .txt in /home/balboa:
/home/balboa/newnew.txt

summarny size ( bytes ) & amount of strings :
  4  1 /home/balboa/newnew.txt
```

---

## task_2_5.sh

Create files with identical content:
```bash
echo "same content" > a.txt
echo "same content" > b.txt
echo "unique" > c.txt
```

Run:
```bash
chmod +x task_2_5.sh
./task_2_5.sh
```

Expected result:
```
Duplicates: 1
a.txt
b.txt
```

Run on a specific directory:
```bash
./task_2_5.sh ~/lab2
```

---

## task_2_6.sh

Run:
```bash
chmod +x task_2_6.sh
./task_2_6.sh a b c d
```

Expected result:
```
Number of arguments: 4
```

---

## filter_numbers.sh

Run:
```bash
chmod +x filter_numbers.sh
./filter_numbers.sh 1 2 3 4 5 6 7 8 9 10
```

Check results:
```bash
cat even.txt
cat odd.txt
```

Expected result:
- `even.txt`: `2 4 8 10`
- `odd.txt`: `1 5 7`
- stdout: `Processed numbers: 10`

---

## smart_calc.sh

Test all operations:

```bash
chmod +x smart_calc.sh

./smart_calc.sh -p add 1 2 3
./smart_calc.sh -p sub 10 3 2
./smart_calc.sh -p mul 2 3 4
./smart_calc.sh -p div 100 5
./smart_calc.sh -p pow 2 10
```

Verbose output:
```bash
./smart_calc.sh -v -p mul 6 7
```

Write the result to a file:
```bash
./smart_calc.sh -o out.txt -p add 5 5
cat out.txt
```

Help:
```bash
./smart_calc.sh -h
```

Combine options:
```bash
./smart_calc.sh -v -o calc.txt -p mul 5 6
cat calc.txt
```

Expected results:
- `add 1 2 3` → `6`
- `sub 10 3 2` → `5`
- `mul 2 3 4` → `24`
- `div 100 5` → `20`
- `pow 2 10` → `1024`

---

## analyze_sales.sh — prepare the CSV file

Create the file:
```bash
nano sales.csv
```

Content of `sales.csv`:
```csv
product,price,quantity
apple,10,5
banana,20,3
cherry,15,7
orange,8,12
grape,25,2
melon,12,4
```

---

## analyze_sales.sh — task 2.9 (text report)

Run:
```bash
chmod +x analyze_sales.sh
./analyze_sales.sh sales.csv
```

Expected result:
```
Total sales: 409.00
Average price: 12.39
Most expensive sale: apple,10,5
```

Check the saved report:
```bash
cat sales_report.txt
```

---

## analyze_sales.sh — task 2.10 (CSV report)

Run:
```bash
./analyze_sales.sh -f csv sales.csv
```

Expected result in `sales_report.csv`:
```
metric,value
total,409.00
average,12.39
best,"apple,10,5"
```

Check:
```bash
cat sales_report.csv
```

---

## analyze_sales.sh — task 2.10 (SQL generation)

Run:
```bash
./analyze_sales.sh -f csv -g sales.csv
```

Check:
```bash
cat import_sales.sql
```

Expected result:
```sql
CREATE TABLE IF NOT EXISTS sales_report (
    metric TEXT PRIMARY KEY,
    value  TEXT
);

INSERT INTO sales_report (metric, value) VALUES ('total', '409.00') ON CONFLICT (metric) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO sales_report (metric, value) VALUES ('average', '12.39') ON CONFLICT (metric) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO sales_report (metric, value) VALUES ('best', '"apple,10,5"') ON CONFLICT (metric) DO UPDATE SET value = EXCLUDED.value;
```

---

