n = 100000
sum = 0
n.times do |i|
  m = {a: i, b: i + 1, c: i + 2}
  sum += m[:b]
end
puts sum
