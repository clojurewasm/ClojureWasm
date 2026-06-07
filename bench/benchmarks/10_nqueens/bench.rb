def solve(n)
  solutions = 0
  queens = []

  safe = ->(row, col) {
    queens.each_with_index do |qc, r|
      return false if qc == col || (qc - col).abs == row - r
    end
    true
  }

  backtrack = ->(row) {
    if row == n
      solutions += 1
      return
    end
    n.times do |col|
      if safe.call(row, col)
        queens.push(col)
        backtrack.call(row + 1)
        queens.pop
      end
    end
  }

  backtrack.call(0)
  solutions
end

puts solve(8)
