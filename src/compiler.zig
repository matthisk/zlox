const std = @import("std");
const scnnr = @import("scanner.zig");

const Compiler = struct {
    scanner: *scnnr.Scanner,

    fn compile(self: *Compiler) !void {
        while (true) {
            const token = scanner.scan(); 

            switch (token.type) {
                
            }
    }
}
