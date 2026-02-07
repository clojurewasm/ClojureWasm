public class Bench {
    interface ICompute {
        long compute(long x);
    }

    static class MultiplierMap implements ICompute {
        long factor;
        MultiplierMap(long factor) { this.factor = factor; }
        public long compute(long x) { return factor * x; }
    }

    public static void main(String[] args) {
        int n = 10000;
        ICompute m = new MultiplierMap(3);
        long sum = 0;
        for (int i = 0; i < n; i++) {
            sum += m.compute(i);
        }
        System.out.println(sum);
    }
}
