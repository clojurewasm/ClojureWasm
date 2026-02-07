n = 10000
records = (0...n).map { |i| {id: i, value: i * 2, active: i % 3 == 0} }
sum = records.select { |r| r[:active] }.sum { |r| r[:value] }
puts sum
