n = 100000
m = {name: "Alice", age: 30, city: "NYC", score: 95, level: 5}
sum = 0
n.times { sum += m[:score] }
puts sum
