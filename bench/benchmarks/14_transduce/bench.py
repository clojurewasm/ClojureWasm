n = 10000
total = 0
for i in range(n):
    v = i * 3
    if v % 2 == 0:
        total += v
print(total)
