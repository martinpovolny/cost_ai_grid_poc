//go:build !rest_watch

package osac

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/golang/protobuf/jsonpb"              //nolint:staticcheck // v2 migration (protojson+dynamicpb) tracked separately
	"github.com/jhump/protoreflect/dynamic"           //nolint:staticcheck // v2 migration tracked separately
	"github.com/jhump/protoreflect/dynamic/grpcdynamic"
	"github.com/jhump/protoreflect/grpcreflect"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

// WatchEvents opens a gRPC streaming connection to the OSAC public
// Events.Watch service using server reflection to dynamically decode
// protobuf messages. Blocks until the context is cancelled or the
// stream ends.
func (c *Client) WatchEvents(ctx context.Context, handler func(Event) error) error {
	var opts []grpc.DialOption

	if tlsCfg := c.TLSConfig(); tlsCfg != nil {
		tlsCopy := tlsCfg.Clone()
		tlsCopy.NextProtos = []string{"h2"}
		opts = append(opts, grpc.WithTransportCredentials(credentials.NewTLS(tlsCopy)))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	addr := c.grpcAddress()
	conn, err := grpc.NewClient(addr, opts...)
	if err != nil {
		return fmt.Errorf("grpc dial %s: %w", addr, err)
	}
	defer func() { _ = conn.Close() }()

	if c.Token() != "" {
		ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+c.Token())
	}

	refClient := grpcreflect.NewClientAuto(ctx, conn)
	svc, err := refClient.ResolveService("osac.public.v1.Events")
	if err != nil {
		return fmt.Errorf("grpc resolve service: %w", err)
	}

	watchMethod := svc.FindMethodByName("Watch")
	if watchMethod == nil {
		return fmt.Errorf("grpc: Watch method not found on osac.public.v1.Events")
	}

	stub := grpcdynamic.NewStub(conn)
	reqMsg := dynamic.NewMessage(watchMethod.GetInputType())

	stream, err := stub.InvokeRpcServerStream(ctx, watchMethod, reqMsg)
	if err != nil {
		return fmt.Errorf("grpc stream open: %w", err)
	}

	c.Logger().Info("watch stream connected", "transport", "grpc", "address", addr)

	for {
		resp, err := stream.RecvMsg()
		if err != nil {
			if err == io.EOF || ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("grpc recv: %w", err)
		}

		dynMsg, ok := resp.(*dynamic.Message)
		if !ok {
			c.Logger().Warn("unexpected message type from grpc stream")
			continue
		}

		jsonBytes, err := dynMsg.MarshalJSONPB(&jsonpb.Marshaler{OrigName: true})
		if err != nil {
			c.Logger().Warn("failed to marshal grpc response to JSON", "error", err)
			continue
		}

		var watchResp struct {
			Event *Event `json:"event,omitempty"`
		}
		if err := json.Unmarshal(jsonBytes, &watchResp); err != nil {
			c.Logger().Warn("failed to parse grpc event JSON", "error", err)
			continue
		}

		if watchResp.Event == nil {
			continue
		}

		if err := handler(*watchResp.Event); err != nil {
			c.Logger().Error("event handler failed", "error", err, "eventID", watchResp.Event.ID)
		}
	}
}

func (c *Client) grpcAddress() string {
	return c.grpcAddr
}
