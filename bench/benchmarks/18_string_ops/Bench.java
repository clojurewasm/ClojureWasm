public class Bench {
    public static void main(String[] args) {
        int n = 100000;
        long sum = 0;
        for (int i = 0; i < n; i++) {
            sum += String.valueOf(i).length();
        }
        System.out.println(sum);
    }
}
