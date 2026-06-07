from functools import reduce

xs = list(range(10000))
mapped = list(map(lambda x: x * x, xs))
filtered = list(filter(lambda x: x % 2 == 0, mapped))
result = reduce(lambda a, b: a + b, filtered, 0)
print(result)
