public class Bench {
    public static void main(String[] args) {
        int n = 10000;
        long[] arr = new long[n];
        for (int i = 0; i < n; i++) arr[i] = i;

        for (int i = 0; i < n; i++) arr[i] = arr[i] * arr[i];

        long sum = 0;
        for (int i = 0; i < n; i++) {
            if (arr[i] % 2 == 0) sum += arr[i];
        }
        System.out.println(sum);
    }
}
