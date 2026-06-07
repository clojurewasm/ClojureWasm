public class Bench {
    static long fib(long n) {
        long a = 0, b = 1;
        for (long i = 0; i < n; i++) {
            long t = a + b;
            a = b;
            b = t;
        }
        return a;
    }

    public static void main(String[] args) {
        System.out.println(fib(25));
    }
}
