n = 100000
total = 0
for i in range(n):
    m = {"a": i, "b": i + 1, "c": i + 2}
    total += m["b"]
print(total)
