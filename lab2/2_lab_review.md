# lab 2 all scritpts
------task_2_1.sh--------

```bash
#!/bin/bash
LOG=/tmp/run.log

if [ -f "$LOG" ]; then
    PREV=$(wc -l < "$LOG")
else
    PREV=0
fi

date >> "$LOG"
echo "Hello, World!"
echo "$PREV" >&2
```

------task_2_2.sh--------

```bash
#!/bin/bash
./task_2_1.sh
less /tmp/run.log
```

------task_2_3.sh--------

```bash
#!/bin/bash
while IFS= read -r line; do
    if echo "$line" | grep -qw 'bin'; then
        echo "$line" >&2
    fi
done
```

------task_2_4.sh--------

```bash
#!/bin/bash
echo "List of .txt files in $HOME:"
find "$HOME" -type f -name '*.txt'

echo
echo "Summary size (bytes) and amount of strings:"
find "$HOME" -type f -name '*.txt' -exec wc -cl {} +
```

------task_2_5.sh--------

```bash
#!/bin/bash
DIR="${1:-.}"

find "$DIR" -type f -exec md5sum {} + 2>/dev/null \
    | sort \
    | awk '
        {
            hash = $1
            $1 = ""
            sub(/^[ *]+/, "")
            files[hash] = files[hash] "\n" $0
            count[hash]++
        }
        END {
            for (h in count) {
                if (count[h] > 1) {
                    print "Duplicates: " count[h] - 1
                    print files[h]
                    print ""
                }
            }
        }'
```

------task_2_6.sh--------

```bash
#!/bin/bash
echo "Number of arguments: $#"
```

------filter_numbers.sh--------

```bash
#!/bin/bash
> even.txt
> odd.txt

count=0

for num in "$@"; do
    count=$((count + 1))

    if (( num % 3 == 0 )); then
        continue
    fi

    if (( num % 2 == 0 )); then
        echo "$num" >> even.txt
    else
        echo "$num" >> odd.txt
    fi
done

echo "Processed numbers: $count"
```

------smart_calc.sh--------

```bash
#!/bin/bash
usage() {
    echo "Usage: $0 [-h] [-v] [-o file] -p operation numbers..."
    echo "  -h           show help"
    echo "  -v           verbose output"
    echo "  -o <file>    output file"
    echo "  -p <op>      operation: add | sub | mul | div | pow"
    exit 0
}

VERBOSE=0
OUTFILE=""
OP=""

while getopts ":hvo:p:" opt; do
    case $opt in
        h) usage ;;
        v) VERBOSE=1 ;;
        o) OUTFILE="$OPTARG" ;;
        p) OP="$OPTARG" ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
        :)  echo "Option -$OPTARG requires an argument" >&2; usage ;;
    esac
done

shift $((OPTIND - 1))

if [ -z "$OP" ] || [ $# -eq 0 ]; then
    usage
fi

result=$1
shift

case $OP in
    add) for n in "$@"; do result=$((result + n)); done ;;
    sub) for n in "$@"; do result=$((result - n)); done ;;
    mul) for n in "$@"; do result=$((result * n)); done ;;
    div)
        for n in "$@"; do
            if [ "$n" -eq 0 ]; then
                echo "Division by zero" >&2
                exit 1
            fi
            result=$((result / n))
        done
        ;;
    pow) for n in "$@"; do result=$((result ** n)); done ;;
    *) echo "Unknown operation: $OP" >&2; exit 1 ;;
esac

[ "$VERBOSE" -eq 1 ] && echo "Operation: $OP" >&2

if [ -n "$OUTFILE" ]; then
    echo "$result" | tee "$OUTFILE"
else
    echo "$result"
fi
```

------analyze_sales.sh ( 2.9)--------

```bash
#!/bin/bash
if [ $# -ne 1 ]; then
    echo "Usage: $0 <sales.csv>" >&2
    exit 1
fi

CSV="$1"

if [ ! -f "$CSV" ]; then
    echo "File not found: $CSV" >&2
    exit 1
fi

awk -F, '
NR > 1 {
    sum += $2 * $3
    cnt += $3
    if ($2 * $3 > max) {
        max = $2 * $3
        best = $0
    }
}
END {
    printf "Total sales: %.2f\n", sum
    printf "Average price: %.2f\n", sum / cnt
    printf "Most expensive sale: %s\n", best
}' "$CSV" | tee sales_report.txt
```

------analyze_sales.sh ( 2.10)--------

```bash
#!/bin/bash
FORMAT="text"
GEN_SQL=0

usage() {
    echo "Usage: $0 [-f csv] [-g] <sales.csv>"
    echo "  -f csv   output report in CSV format"
    echo "  -g       generate SQL for postgresql import"
    exit 0
}

while getopts ":f:gh" opt; do
    case $opt in
        f) FORMAT="$OPTARG" ;;
        g) GEN_SQL=1 ;;
        h) usage ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
        :)  echo "Option -$OPTARG requires an argument" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -ne 1 ]; then
    usage
fi

CSV="$1"
[ ! -f "$CSV" ] && { echo "File not found: $CSV" >&2; exit 1; }

read -r TOTAL AVG BEST <<< "$(awk -F, '
NR > 1 {
    sum += $2 * $3
    cnt += $3
    if ($2 * $3 > max) {
        max = $2 * $3
        best = $0
    }
}
END {
    printf "%.2f %.2f \"%s\"", sum, sum / cnt, best
}' "$CSV")"

if [ "$FORMAT" = "csv" ]; then
    {
        echo "metric,value"
        echo "total,$TOTAL"
        echo "average,$AVG"
        echo "best,$BEST"
    } | tee sales_report.csv
else
    {
        echo "Total sales: $TOTAL"
        echo "Average price: $AVG"
        echo "Most expensive sale: $BEST"
    } | tee sales_report.txt
fi

if [ "$GEN_SQL" -eq 1 ]; then
    cat <<'SQL' > import_sales.sql
CREATE TABLE IF NOT EXISTS sales_report (
    metric TEXT PRIMARY KEY,
    value  TEXT
);

SQL
    while IFS=, read -r metric value; do
        [ "$metric" = "metric" ] && continue
        printf "INSERT INTO sales_report (metric, value) VALUES ('%s', '%s') ON CONFLICT (metric) DO UPDATE SET value = EXCLUDED.value;\n" \
            "$metric" "$value"
    done < sales_report.csv >> import_sales.sql

    echo "SQL queries saved to import_sales.sql"
fi
```

------sales.csv--------

```csv
product,price,quantity
apple,10,5
banana,20,3
cherry,15,7
orange,8,12
grape,25,2
melon,12,4
