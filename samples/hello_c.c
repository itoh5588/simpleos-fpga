int main() {
    int x;
    puts("Hello from Simple-C on FPGA!\n");
    x = 123 * 7;
    x = x / 7;
    if (x == 123) {
        puts("C arithmetic PASS\n");
        return 5;
    }
    puts("C arithmetic FAIL\n");
    return 8;
}
