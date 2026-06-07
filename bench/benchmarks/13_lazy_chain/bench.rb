sum = 0
count = 0
i = 0
while count < 10000
  v = i * 3
  if v.even?
    sum += v
    count += 1
  end
  i += 1
end
puts sum
