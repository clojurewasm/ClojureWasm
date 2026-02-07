n = 10000
m = {"a": {"b": {"c": 0}}}
for _ in range(n):
    m["a"]["b"]["c"] += 1
print(m["a"]["b"]["c"])
