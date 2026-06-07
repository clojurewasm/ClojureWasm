def process(data):
    t = data["type"]
    if t == "add":
        return data["a"] + data["b"]
    elif t == "mul":
        return data["a"] * data["b"]
    elif t == "sub":
        return data["a"] - data["b"]

n = 10000
data = {"type": "add", "a": 3, "b": 4}
total = 0
for _ in range(n):
    total += process(data)
print(total)
