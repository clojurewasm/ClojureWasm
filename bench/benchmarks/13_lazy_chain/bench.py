total = 0
count = 0
i = 0
while count < 10000:
    v = i * 3
    if v % 2 == 0:
        total += v
        count += 1
    i += 1
print(total)
