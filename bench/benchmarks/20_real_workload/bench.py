n = 10000
records = [{"id": i, "value": i * 2, "active": i % 3 == 0} for i in range(n)]
total = sum(r["value"] for r in records if r["active"])
print(total)
