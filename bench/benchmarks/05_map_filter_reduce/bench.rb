xs = (0...10000).to_a
mapped = xs.map { |x| x * x }
filtered = mapped.select { |x| x.even? }
result = filtered.reduce(0, :+)
puts result
