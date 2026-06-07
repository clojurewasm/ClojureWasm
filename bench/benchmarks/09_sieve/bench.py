def sieve(limit):
    candidates = list(range(2, limit + 1))
    count = 0
    while candidates:
        p = candidates[0]
        count += 1
        candidates = [x for x in candidates[1:] if x % p != 0]
    return count

print(sieve(1000))
