// The command-line and macOS app entry points share the same game runtime.
extern "C" int port_game_main(int argc, char** argv);

int main(int argc, char** argv)
{
    return port_game_main(argc, argv);
}
