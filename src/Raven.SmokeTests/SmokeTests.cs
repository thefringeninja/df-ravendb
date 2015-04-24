using System;
using System.Linq;
using System.Threading.Tasks;
using FluentAssertions;
using Raven.Abstractions.Extensions;
using Raven.Client;
using Raven.Client.Linq;
using Raven.Client.Embedded;
using Raven.Client.Indexes;
using Xunit;
namespace Raven.SmokeTests
{
    public class SmokeTests : IDisposable
    {
        private readonly IDocumentStore _documentStore;

        public SmokeTests()
        {
            _documentStore = new EmbeddableDocumentStore
            {
                RunInMemory = true,
                Configuration =
                {
                    Settings =
                    {
                        {"Raven/AssembliesDirectory", "~/assemblies-" + Guid.NewGuid().ToString("n")}
                    }
                }
            }.Initialize();

            Raven.Abstractions.Logging.LogManager.CurrentLogManager = new Raven.Abstractions.Logging.LogProviders.NLogLogManager();
        }

        [Fact]
        public async Task can_save_and_load()
        {
            using (var session = _documentStore.OpenAsyncSession())
            {
                await session.StoreAsync(new Order
                {
                    Id = "Order/1",
                    Freight = 100
                });

                await session.SaveChangesAsync();
            }

            using (var session = _documentStore.OpenAsyncSession())
            {
                var document = await session.LoadAsync<Order>("Order/1");

                document.Freight.Should().Be(100);
            }
        }

        [Fact]
        public async Task simple_transformer()
        {
            await new Orders_Company().ExecuteAsync(_documentStore);

            var orderCount = 1024;
            var customerCount = 32;

            var companies = Enumerable.Range(1, customerCount)
                .Select(id => new Company
                {
                    Id = "Company/" + id
                });

            var orders = Enumerable.Range(1, orderCount)
                .Select(id => new Order
                {
                    Company = "Company/" + ((id%customerCount) + 1),
                    Freight = id*2,
                    Id = "Order/" + id
                });


            using (var operation = _documentStore.BulkInsert())
            {
                companies.OfType<object>()
                    .Union(orders)
                    .ForEach(x => operation.Store(x));

                await operation.DisposeAsync();
            }

            using (var session = _documentStore.OpenAsyncSession())
            {
                var results = await (session.Query<Order>()
                    .Where(x => x.Freight > 100) // remember to add `Raven.Client.Linq` namespace
                    .ToListAsync());

                results.Count.Should().BeGreaterThan(1);
            }

            using (var session = _documentStore.OpenAsyncSession())
            {
                var results = await (session.Query<Order>()
                    .Where(x => x.Freight > 100) // remember to add `Raven.Client.Linq` namespace
                    .TransformWith<Orders_Company, string>()
                    .ToListAsync());

                results.Count.Should().BeGreaterThan(1);
            }
        }

        [Fact]
        public async Task complicated_transformers()
        {
            await new GetNode.Transformer().ExecuteAsync(_documentStore);
            var count = 28;
            using (var session = _documentStore.OpenAsyncSession())
            {
                foreach (var i in Enumerable.Range(1, count))
                {
                    var p = new GetNode.NodeProjection()
                    {
                        Id = "node/" + i,
                        Name = "Node " + i,
                        References = new[]
                        {
                            "node/" + (i-1)
                        }
                    };
                    await session.StoreAsync(p);
                }
                await session.SaveChangesAsync();
            }

            using (var session = _documentStore.OpenAsyncSession())
            {
                foreach (var i in Enumerable.Range(1, count))
                {
                    var node = await session.LoadAsync<GetNode.NodeProjection>("node/" + i);
                }
            }
            using (var session = _documentStore.OpenAsyncSession())
            {
                foreach (var i in Enumerable.Range(1, count))
                {
                    var node = await session.LoadAsync<GetNode.Transformer, GetNode.NodeProjection>("node/" + i);
                }
            }

        }

        public void Dispose()
        {
            _documentStore.Dispose();
        }

        class Company
        {
            public string Id { get; set; }
        }

        class Order
        {
            public string Id { get; set; }

            public string Company { get; set; }

            public int Freight { get; set; }
        }

        class Orders_Company : AbstractTransformerCreationTask<Order>
        {
            public Orders_Company()
            {
                TransformResults = results => from result in results select result.Company;
            }
        }
    }
}