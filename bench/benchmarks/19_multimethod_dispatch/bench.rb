def process(data)
  case data[:type]
  when :add then data[:a] + data[:b]
  when :mul then data[:a] * data[:b]
  when :sub then data[:a] - data[:b]
  end
end

n = 10000
data = {type: :add, a: 3, b: 4}
sum = 0
n.times { sum += process(data) }
puts sum
