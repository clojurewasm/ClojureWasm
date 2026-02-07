n = 10000
sum = 0
n.times do |i|
  v = i * 3
  sum += v if v.even?
end
puts sum
