public class Bench {
    public static void main(String[] args) {
        long n = 1000000;
        long sum = 0;
        for (long i = 0; i < n; i++) {
            sum += i;
        }
        System.out.println(sum);
    }
}
