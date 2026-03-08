const User = struct {
    id: u32,
    username: []const u8,
    email: []const u8,
    created_at: []const u8,
};

const ErrorResponse = struct {
    code: u16,
    message: []const u8,
};

const SystemHealth = struct {
    pub const path = "/health";
    pub const method = zenerator.Method.GET;
    pub const Request = struct {
        pub const Params = struct {};
        pub const Query = struct {};
        pub const Body = struct {};
    };
    pub const Response = struct {
        status: []const u8,
        uptime: u64,
    };
};

const UserList = struct {
    pub const path = "/users";
    pub const method = zenerator.Method.GET;
    pub const Request = struct {
        pub const Params = struct {};

        pub const Query = struct {
            page: u32,
            limit: ?u32,
            search: ?[]const u8,
        };
        pub const Body = struct {};
    };

    pub const Response = []const User;
};

const UserGet = struct {
    pub const path = "/users/:id";
    pub const method = zenerator.Method.GET;
    pub const Request = struct {
        pub const Params = struct {
            id: u32,
        };
        pub const Query = struct {};
        pub const Body = struct {};
    };
    pub const Response = User;
};

const UserCreate = struct {
    pub const path = "/users";
    pub const method = zenerator.Method.POST;
    pub const Request = struct {
        pub const Params = struct {};
        pub const Query = struct {};

        pub const Body = struct {
            username: []const u8,
            password: []const u8,
            email: []const u8,
            age: ?u8,
        };
    };
    pub const Response = struct {
        id: u32,
        success: bool,
    };
};

const UserUpdate = struct {
    pub const path = "/users/:id";
    pub const method = zenerator.Method.PATCH;
    pub const Request = struct {
        pub const Params = struct {
            id: u32,
        };
        pub const Query = struct {};

        pub const Body = struct {
            email: ?[]const u8,
            username: ?[]const u8,
        };
    };
    pub const Response = User;
};

const UserDelete = struct {
    pub const path = "/users/:id";
    pub const method = zenerator.Method.DELETE;
    pub const Request = struct {
        pub const Params = struct {
            id: u32,
        };
        pub const Query = struct {};
        pub const Body = struct {};
    };
    pub const Response = struct {
        success: bool,
    };
};

const PostCreate = struct {
    pub const path = "/users/:userId/posts";
    pub const method = zenerator.Method.POST;
    pub const Request = struct {
        pub const Params = struct {
            userId: u32,
        };
        pub const Query = struct {};
        pub const Body = struct {
            title: []const u8,
            content: []const u8,
        };
    };
    pub const Response = struct {
        id: u32,
        title: []const u8,
    };
};

pub const API = struct {
    pub const routes = .{
        .{
            SystemHealth,
        },
        .{
            UserList,
            UserGet,
            UserCreate,
            UserUpdate,
            UserDelete,
        },
        .{
            PostCreate,
        },
    };
};

const std = @import("std");
const zenerator = @import("openapi_zenerator");
