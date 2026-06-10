total = 0
for _ in range(5):
    v = list(range(5000, 0, -1))
    v.sort()
    total = sum(v[:100])
print(total)
