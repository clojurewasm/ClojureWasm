public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        long sum = 0;
        for (int i = 0; i < n; i++) {
            long v = (long) i * 3;
            if (v % 2 == 0) sum += v;
        }
        System.out.println(sum);
    }
}
