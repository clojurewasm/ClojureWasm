n = 100000
m = {"name": "Alice", "age": 30, "city": "NYC", "score": 95, "level": 5}
total = 0
for _ in range(n):
    total += m["score"]
print(total)
