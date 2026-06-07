class Computable
  def initialize(factor)
    @factor = factor
  end
  def compute(x)
    @factor * x
  end
end

n = 10000
m = Computable.new(3)
sum = 0
n.times { |i| sum += m.compute(i) }
puts sum
